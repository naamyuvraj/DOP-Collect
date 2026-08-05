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

  try {
    const body = await req.json();
    const action = String(body.action || "");
    const agentId = String(body.agentId || "").trim();
    if (!agentId) return json({ ok: false, error: "no_agent" }, 400);

    // --- Abuse guard: optional Play Integrity + rate limits (per device, per
    // IP, per agent) — same posture as the groq/ingest proxies. Order/verify are
    // sensitive; status is called often, so limits are generous.
    const { data: intCfg } = await sb
      .from("app_config").select("value").eq("key", "require_integrity").maybeSingle();
    if (intCfg?.value === true && !req.headers.get("x-integrity-token"))
      return json({ ok: false, error: "integrity_required" }, 403);

    const device = (req.headers.get("x-device-id") || agentId).slice(0, 64);
    const ip = (req.headers.get("x-forwarded-for") || "noip").split(",")[0].trim();
    const bump = async (k: string, s: number): Promise<number> =>
      ((await sb.rpc("bump_rate", { p_device: k, p_window_secs: s })).data as number) ?? 0;
    if ((await bump(`pay:${device}`, 60)) > 30) return json({ ok: false, error: "rate_limited" }, 429);
    if ((await bump(`pay:${device}:d`, 86400)) > 300) return json({ ok: false, error: "rate_limited" }, 429);
    if ((await bump(`pay:ip:${ip}`, 3600)) > 200) return json({ ok: false, error: "rate_limited" }, 429);

    const trialDays = Number(
      (await sb.from("app_config").select("value").eq("key", "trial_days").maybeSingle())
        .data?.value ?? 14
    ) || 14;

    const loadPlans = async () =>
      (await sb.from("plans").select("*").eq("active", true).order("sort")).data || [];

    // Resolve (and lazily trial-grant) the subscription.
    const resolve = async () => {
      let { data: sub } = await sb
        .from("subscriptions").select("*").eq("agent_id", agentId).maybeSingle();
      if (!sub) {
        const end = new Date(Date.now() + trialDays * 86400_000).toISOString();
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
      const { data: plan } = await sb
        .from("plans").select("*").eq("code", String(body.planCode)).maybeSingle();
      if (!plan || Number(plan.price_inr) <= 0)
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
      return json({
        ok: true, orderId: order.id, amount: order.amount,
        currency: order.currency, keyId, planName: plan.name,
      });
    }

    if (action === "verify") {
      if (!keySecret) return json({ ok: false, error: "not_configured" }, 503);
      const { orderId, paymentId, signature, planCode } = body;
      const expected = await hmacHex(keySecret, `${orderId}|${paymentId}`);
      if (!timingSafeEqual(expected, String(signature ?? "")))
        return json({ ok: false, error: "bad_signature" }, 400);

      const { data: plan } = await sb
        .from("plans").select("*").eq("code", String(planCode)).maybeSingle();
      if (!plan) return json({ ok: false, error: "bad_plan" }, 400);

      // IDEMPOTENCY: a valid signature could otherwise be REPLAYED to stack free
      // subscription time. If this Razorpay payment was already recorded, return
      // the current state without extending again.
      const { data: dup } = await sb
        .from("payments").select("id").eq("ref", String(paymentId)).maybeSingle();
      if (dup) {
        const r0 = await resolve();
        return json({ ok: true, status: r0.status, periodEnd: r0.sub.current_period_end,
          note: "already_processed" });
      }

      // Extend from the later of now / current end, so paying early stacks.
      const r = await resolve();
      const base = Math.max(Date.now(), new Date(r.sub.current_period_end).getTime());
      const newEnd = new Date(base + plan.duration_days * 86400_000).toISOString();
      // Record the payment FIRST (unique ref enforces idempotency at the DB
      // level even under a race); only extend if that insert wins.
      const pay = await sb.from("payments").insert({
        agent_id: agentId, plan_code: plan.code, amount: plan.price_inr,
        currency: "INR", provider: "razorpay", ref: String(paymentId),
        order_id: String(orderId), status: "success", plan: plan.code,
      });
      if (pay.error) {
        const r0 = await resolve();
        return json({ ok: true, status: r0.status, periodEnd: r0.sub.current_period_end,
          note: "already_processed" });
      }
      await sb.from("subscriptions").upsert({
        agent_id: agentId, plan_code: plan.code, status: "active",
        current_period_end: newEnd, updated_at: new Date().toISOString(),
      });
      return json({ ok: true, status: "active", periodEnd: newEnd });
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
