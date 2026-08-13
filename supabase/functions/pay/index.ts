// Supabase Edge Function: pay
// ---------------------------------------------------------------------------
// Subscriptions/payments authority for Razorpay. The app carries NO Razorpay
// secret — key_secret lives here. Actions:
//   status  -> {status, planCode, periodEnd, daysLeft, plans[]}  (auto-grants a
//              trial the first time an agent is seen)
//   order   -> create a Razorpay order for a plan -> {orderId, amount, keyId}
//   verify  -> verify the payment signature, extend the subscription, record it
//
// Entitlement is keyed by the DOP agent_id. Everything is a no-op unless
// app_config.payments_enabled = true (the app also gates on it).
//
// AUTH: every action requires a live device session token (issued by the `otp`
// function) and derives the agent id FROM that session. A client-supplied agent
// id is never trusted — it used to be, which let anyone read any agent's plan
// and expiry just by guessing an id that is printed on receipts.
//   => `otp_required` must be ON before `payments_enabled` is turned on,
//      otherwise no device has a session and every call here 401s (the app
//      fails open, so nobody is blocked — the paywall simply won't function).
//
// Secrets: RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET.
// Deploy:  supabase functions deploy pay --project-ref ojorpmtptryldizogtkz
// ---------------------------------------------------------------------------
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-device-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

async function hmacHex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** A row of the `plans` price list. */
interface PlanRow {
  code: string;
  name?: string;
  price_inr?: number;
  duration_days?: number;
}

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time string compare (don't leak the signature via timing). */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
  const keyId = Deno.env.get("RAZORPAY_KEY_ID") || "";
  const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET") || "";

  /**
   * The DOP agent id this session belongs to, or null when the token is
   * missing, unknown, revoked or the account is disabled. Identity comes from
   * here and nowhere else — a client-supplied agent id is only a claim, and
   * agent ids are printed on receipts.
   */
  const sessionAgent = async (token: string): Promise<string | null> => {
    if (!token) return null;
    const { data: s } = await sb
      .from("device_sessions")
      .select("account_id, revoked_at")
      .eq("token_hash", await sha256(token))
      .maybeSingle();
    if (!s || s.revoked_at) return null;
    const { data: acct } = await sb
      .from("accounts").select("agent_id, disabled").eq("id", s.account_id).maybeSingle();
    if (!acct || acct.disabled) return null;
    const id = String(acct.agent_id ?? "").trim();
    return id || null;
  };

  try {
    const body = await req.json();
    const action = String(body.action || "");
    // Identity from the session token only — never from body.agentId. Null
    // here means "we don't know who this is", not "reject": see the `status`
    // branch below, which still has a public half.
    const agentId = await sessionAgent(String(body.token || ""));

    // --- Abuse guard: optional Play Integrity + rate limits (per device, per
    // IP, per agent) — same posture as the groq/ingest proxies. Order/verify are
    // sensitive; status is called often, so limits are generous.
    const { data: intCfg } = await sb
      .from("app_config").select("value").eq("key", "require_integrity").maybeSingle();
    if (intCfg?.value === true && !req.headers.get("x-integrity-token"))
      return json({ ok: false, error: "integrity_required" }, 403);

    const device = (req.headers.get("x-device-id") || agentId || "anon").slice(0, 64);
    const ip = (req.headers.get("x-forwarded-for") || "noip").split(",")[0].trim();
    const bump = async (k: string, s: number): Promise<number> => {
      const r = await sb.rpc("bump_rate", { p_device: k, p_window_secs: s });
      // Deliberately fails OPEN: a broken counter must not stop an agent paying
      // or the paywall rendering. It must not be silent either — with Play
      // Integrity still dormant these limits are the only abuse control on the
      // anon key, and returning 0 disables every one of them at once.
      if (r.error) {
        console.error("bump_rate failed — rate limiting is OFF for this call", k, r.error);
        return 0;
      }
      return (r.data as number) ?? 0;
    };
    if ((await bump(`pay:${device}`, 60)) > 30) return json({ ok: false, error: "rate_limited" }, 429);
    if ((await bump(`pay:${device}:d`, 86400)) > 300) return json({ ok: false, error: "rate_limited" }, 429);
    if ((await bump(`pay:ip:${ip}`, 3600)) > 200) return json({ ok: false, error: "rate_limited" }, 429);

    const paymentsEnabled =
      (await sb.from("app_config").select("value").eq("key", "payments_enabled").maybeSingle())
        .data?.value === true;

    const plans =
      (await sb.from("plans").select("*").eq("active", true).order("sort")).data || [];
    const loadPlans = () => plans;

    // How long a trial runs. ONE source of truth: the `trial` plan row, because
    // that is the number the paywall shows the agent ("Free trial · 60 days").
    // These used to disagree — the plan list advertised 60 days while the grant
    // came from app_config.trial_days, which isn't set, so the code silently
    // used its 14-day default. app_config is honoured only when there is no
    // trial plan at all; 14 is the last resort.
    const trialPlan = (plans as PlanRow[]).find((p) => p.code === "trial");
    const cfgTrialDays =
      (await sb.from("app_config").select("value").eq("key", "trial_days").maybeSingle())
        .data?.value;
    const trialDays =
      Number(trialPlan?.duration_days ?? cfgTrialDays ?? 14) || 14;

    // --- The public half -----------------------------------------------------
    // The plan list is a PRICE LIST, not agent data: the paywall has to render
    // it before anyone is signed in, and it reveals nothing about anybody.
    // Locking the whole function behind a session made the screen come up empty
    // with a dead Retry button on any device without one.
    //
    // Entitlement is still private, so an unauthenticated caller gets no
    // status, no expiry, and no way to ask about someone else — `agentId` is
    // never read from the body, so there is nothing to leak.
    if (!agentId) {
      if (action === "status") {
        return json({
          ok: true, status: "unknown", planCode: "", periodEnd: null,
          daysLeft: 0, plans: await loadPlans(),
        });
      }
      // Buying, and confirming a purchase, are always tied to an agent.
      return json({ ok: false, error: "unauthorized" }, 401);
    }

    // --- Self-serve billing switch ------------------------------------------
    // Pricing is currently agreed per agent from their book size and usage, so
    // there is no published tier anyone may simply buy. `status` stays open —
    // an agent still needs to see their trial — but nothing that could take
    // money is reachable, whatever the client thinks. Flip
    // app_config.self_serve_billing to true when there is a price to sell.
    const selfServe =
      (await sb.from("app_config").select("value").eq("key", "self_serve_billing")
        .maybeSingle()).data?.value === true;
    if (!selfServe && (action === "order" || action === "verify")) {
      return json({ ok: false, error: "billing_not_open" }, 403);
    }

    // Resolve (and lazily trial-grant) the subscription.
    const resolve = async () => {
      let { data: sub } = await sb
        .from("subscriptions").select("*").eq("agent_id", agentId).maybeSingle();
      if (!sub) {
        const end = new Date(Date.now() + trialDays * 86400_000).toISOString();
        // While the paywall is OFF, don't persist a row for every agent id that
        // ever opens the app (unauthenticated => trial-row spam). Return an
        // ephemeral trial; a real row is created lazily once payments are on.
        if (!paymentsEnabled) {
          return {
            sub: { agent_id: agentId, plan_code: "trial", current_period_end: end },
            status: "trial",
            daysLeft: trialDays,
          };
        }
        const ins = await sb.from("subscriptions")
          .insert({ agent_id: agentId, plan_code: "trial", status: "trial", current_period_end: end })
          .select("*").single();
        if (ins.error || !ins.data)
          throw new Error(
            "subscriptions table not ready — run admin/schema_payments.sql. " +
              (ins.error?.message ?? "")
          );
        sub = ins.data;
      }
      const active = new Date(sub!.current_period_end).getTime() > Date.now();
      const status = active ? (sub!.plan_code === "trial" ? "trial" : "active") : "expired";
      const daysLeft = Math.max(0, Math.ceil(
        (new Date(sub!.current_period_end).getTime() - Date.now()) / 86400_000));
      return { sub: sub!, status, daysLeft };
    };

    // Activate/extend from the SERVER-recorded order (never client input), and
    // idempotent: the unique payment `ref` index makes replay/race a no-op.
    const activate = async (orderId: string, paymentId: string) => {
      const { data: ord } = await sb
        .from("orders").select("agent_id, plan_code, amount").eq("order_id", orderId)
        .maybeSingle();
      if (!ord) return { ok: false, error: "unknown_order" } as const;
      // Confirm only your OWN order. Activation credits `ord.agent_id` and needs
      // a genuine Razorpay signature, so this was never a way to take someone
      // else's entitlement — but "any live session may push any order through"
      // is a wider door than this flow needs, and it made the session check on
      // `verify` decorative. The webhook is unaffected: it has no session and is
      // authenticated by Razorpay's own signature over the raw body.
      if (ord.agent_id !== agentId) {
        console.error("verify: order belongs to another agent", orderId, agentId);
        return { ok: false, error: "not_your_order" } as const;
      }
      // Deliberately NOT filtered on `active`, unlike the `order` branch: an
      // order placed while a tier was on sale must still activate after that
      // tier is retired. What you may BUY is today's price list; what you have
      // already PAID for is the order.
      const { data: plan } = await sb
        .from("plans").select("code, price_inr, duration_days").eq("code", ord.plan_code).maybeSingle();
      if (!plan) return { ok: false, error: "bad_plan" } as const;
      const endOf = async (): Promise<string | null> => {
        const { data: s } = await sb.from("subscriptions")
          .select("current_period_end").eq("agent_id", ord.agent_id).maybeSingle();
        return s?.current_period_end ?? null;
      };
      // `payments.amount` is RUPEES throughout (numeric(10,2), summed by v_mrr,
      // rendered by the dashboard's inr()); `orders.amount` is paise, because
      // that is what Razorpay was told to charge. Prefer the order: it is what
      // the agent actually paid, whereas the plan's price may have been edited
      // in the dashboard between checkout and capture.
      const paidInr = typeof ord.amount === "number"
        ? ord.amount / 100
        : Number(plan.price_inr);
      const row = {
        agent_id: ord.agent_id, plan_code: plan.code, amount: paidInr,
        currency: "INR", provider: "razorpay", ref: paymentId, order_id: orderId,
        status: "success", plan: plan.code,
      };
      const pay = await sb.from("payments").insert(row);
      // Any failure OTHER than a unique-ref collision (missing column, RLS,
      // connection) left the subscription un-extended, so it must surface as an
      // error: reporting a paid agent "ok" while their expiry never moved is the
      // one outcome this flow must never produce.
      if (pay.error) {
        if (pay.error.code !== "23505") {
          console.error("payments insert failed", orderId, paymentId, pay.error);
          return { ok: false, error: "record_failed" } as const;
        }
        // A row already EXISTS for this payment id — which is not the same as
        // this payment being SETTLED. The webhook writes a `failed` row on
        // payment.failed, and Razorpay reuses the payment id when such a payment
        // is later authorised and captured (late authorisation). Reading every
        // 23505 as "the other path already did this" swallowed that capture: the
        // agent paid, and their expiry never moved.
        //
        // So claim the row and let the database pick the winner. Excluding the
        // SETTLED states means exactly one caller can flip a row that is neither
        // — the loser's UPDATE re-checks its WHERE after the row lock is
        // released and matches nothing — which keeps the verify/webhook race to
        // a single extension while still letting a genuine failed->captured
        // through. `refunded` is excluded too: a late redelivery of a capture we
        // have since refunded must not quietly hand the time back.
        const claim = await sb.from("payments").update(row)
          .eq("provider", "razorpay").eq("ref", paymentId)
          .neq("status", "success").neq("status", "refunded")
          .select("id");
        if (claim.error) {
          console.error("payments claim failed", orderId, paymentId, claim.error);
          return { ok: false, error: "record_failed" } as const;
        }
        if (!(claim.data as unknown[] | null)?.length) {
          return { ok: true, already: true, periodEnd: await endOf() } as const;
        }
        // Claim won — fall through and extend, exactly once.
      }
      const cur = await endOf();
      const base = Math.max(Date.now(), cur ? new Date(cur).getTime() : 0);
      const newEnd = new Date(base + Number(plan.duration_days) * 86400_000).toISOString();
      const ext = await sb.from("subscriptions").upsert({
        agent_id: ord.agent_id, plan_code: plan.code, status: "active",
        current_period_end: newEnd, updated_at: new Date().toISOString(),
      });
      // The payment is on record but access was NOT extended — the same "must
      // never report ok" rule as above. This one can't be retried automatically
      // (the payment row now exists, so a replay short-circuits), so it is the
      // case that needs a human: log everything needed to grant the days by hand.
      if (ext.error) {
        console.error("subscription not extended", orderId, paymentId,
          ord.agent_id, plan.code, ext.error);
        return { ok: false, error: "activate_failed" } as const;
      }
      return { ok: true, periodEnd: newEnd } as const;
    };

    if (action === "status") {
      const r = await resolve();
      return json({
        ok: true, status: r.status, planCode: r.sub.plan_code,
        periodEnd: r.sub.current_period_end, daysLeft: r.daysLeft,
        plans: await loadPlans(),
      });
    }

    if (action === "order") {
      if (!keyId || !keySecret) return json({ ok: false, error: "not_configured" }, 503);
      // Sell only what the price list actually OFFERS. `plans` is the same
      // active-only list `status` hands the paywall, so "what you may buy" and
      // "what you were shown" are one query and cannot drift. Looking the row up
      // by code alone meant a RETIRED tier was still buyable at its old price by
      // anyone who remembered the code — which made `plans.active`, the
      // dashboard's advertised per-plan kill switch, purely cosmetic. A plan
      // saved with a 0-day duration is refused for the same reason a 0-price one
      // is: it would take the money and grant nothing.
      const plan = (plans as PlanRow[]).find((p) => p.code === String(body.planCode));
      if (!plan || Number(plan.price_inr) <= 0 || Number(plan.duration_days) <= 0)
        return json({ ok: false, error: "bad_plan" }, 400);
      const rzp = await fetch("https://api.razorpay.com/v1/orders", {
        method: "POST",
        headers: {
          Authorization: "Basic " + btoa(`${keyId}:${keySecret}`),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          amount: Math.round(Number(plan.price_inr) * 100), // paise
          currency: "INR",
          // Razorpay caps `receipt` at 40 chars — keep it short; the agent id
          // lives in `notes`.
          receipt: `dop_${Date.now()}`,
          notes: { agent_id: agentId, plan: plan.code },
        }),
      });
      const order = await rzp.json();
      if (!rzp.ok)
        return json(
          { ok: false, error: order?.error?.description ?? "razorpay", detail: order },
          502
        );
      // Record the order so verify/webhook derive the plan from HERE, not the
      // client (prevents paying for a cheap plan and claiming an expensive one).
      //
      // This insert MUST be checked. Both activation paths look the order up and
      // give up when it's missing (`unknown_order` / a silent webhook return), so
      // an unrecorded order means: the agent pays, nothing activates, and there
      // is no row anywhere tying the charge to them. Failing here instead costs
      // nothing — no money has moved yet, and the Razorpay order simply expires
      // unpaid — whereas failing one step later costs a real payment.
      const rec = await sb.from("orders").insert({
        order_id: order.id, agent_id: agentId, plan_code: plan.code, amount: order.amount,
      });
      if (rec.error) {
        console.error("order not recorded", order.id, agentId, rec.error);
        return json({ ok: false, error: "not_recorded" }, 500);
      }
      return json({
        ok: true, orderId: order.id, amount: order.amount,
        currency: order.currency, keyId, planName: plan.name,
      });
    }

    if (action === "verify") {
      if (!keySecret) return json({ ok: false, error: "not_configured" }, 503);
      const orderId = String(body.orderId ?? "");
      const paymentId = String(body.paymentId ?? "");
      const expected = await hmacHex(keySecret, `${orderId}|${paymentId}`);
      if (!timingSafeEqual(expected, String(body.signature ?? "")))
        return json({ ok: false, error: "bad_signature" }, 400);
      // Plan + agent come from the recorded order (client planCode is ignored).
      const res = await activate(orderId, paymentId);
      if (!res.ok) return json({ ok: false, error: res.error }, 400);
      return json({
        ok: true, status: "active", periodEnd: res.periodEnd,
        note: "already" in res && res.already ? "already_processed" : undefined,
      });
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
