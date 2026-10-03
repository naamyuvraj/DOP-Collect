// Supabase Edge Function: razorpay-webhook
// ---------------------------------------------------------------------------
// Server-authoritative payment activation. Razorpay calls this directly on
// `payment.captured`, so even if the app is killed right after paying (before
// its own verify), the subscription still activates. Idempotent with the app's
// verify — whichever lands first wins; the other no-ops (unique payment ref).
//
// Razorpay signs the RAW body: X-Razorpay-Signature = HMAC_SHA256(body, secret).
//
// IMPORTANT: deploy with --no-verify-jwt (Razorpay sends no Supabase auth):
//   supabase functions deploy razorpay-webhook --project-ref ojorpmtptryldizogtkz --use-api --no-verify-jwt
// Secret: RAZORPAY_WEBHOOK_SECRET (also set on the Razorpay dashboard webhook).
// ---------------------------------------------------------------------------
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

async function hmacHex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const s = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(s)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const raw = await req.text();
  const secret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET") || "";
  const sig = req.headers.get("x-razorpay-signature") || "";
  if (!secret || !timingSafeEqual(await hmacHex(secret, raw), sig)) {
    return new Response("invalid signature", { status: 400 });
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  /**
   * What happened to one event, and therefore what Razorpay should be told.
   *   ok        — activated here
   *   settled   — a genuine duplicate; the app's own verify got there first
   *   ignored   — not actionable (not our order, plan gone); a retry can't help
   *   retry     — a transient write failure; sending it again genuinely helps
   *   stranded  — the payment is recorded but access was NOT extended
   */
  type Outcome = "ok" | "settled" | "ignored" | "retry" | "stranded";

  // Same activation as pay/verify — plan + agent from the recorded order.
  // A closure over `sb` rather than a parameter: `ReturnType<typeof
  // createClient>` resolves the client's generics to their bare defaults, which
  // doesn't match the inferred type of an actual call, and the mismatch made
  // this whole file fail `deno check` (13 errors) — so nothing in it was ever
  // typechecked.
  const activate = async (
    orderId: string,
    paymentId: string,
  ): Promise<Outcome> => {
    const { data: ord } = await sb
      .from("orders").select("agent_id, plan_code, amount").eq("order_id", orderId)
      .maybeSingle();
    // Either not ours (a shared Razorpay account) or an order that never got
    // recorded. A retry can't conjure the row, so this needs a human, not a
    // redelivery — but it must not be silent: it is a captured payment we
    // cannot attribute to anyone.
    if (!ord) {
      console.error("webhook: no recorded order", orderId, paymentId);
      return "ignored";
    }
    // Not filtered on `active`: a tier retired after this order was placed must
    // still activate. See the matching note in pay/index.ts.
    const { data: plan } = await sb
      .from("plans").select("code, price_inr, duration_days").eq(
        "code",
        ord.plan_code,
      ).maybeSingle();
    if (!plan) {
      console.error(
        "webhook: order references a missing plan",
        orderId,
        ord.plan_code,
      );
      return "ignored";
    }
    // Rupees — see the matching note in pay/index.ts. `orders.amount` is the
    // paise figure Razorpay was actually told to charge.
    const paidInr = typeof ord.amount === "number"
      ? ord.amount / 100
      : Number(plan.price_inr);
    const row = {
      agent_id: ord.agent_id,
      plan_code: plan.code,
      amount: paidInr,
      currency: "INR",
      provider: "razorpay",
      ref: paymentId,
      order_id: orderId,
      status: "success",
      plan: plan.code,
    };
    const pay = await sb.from("payments").insert(row);
    if (pay.error) {
      // Not a duplicate — nothing was recorded and the subscription below is NOT
      // extended. Ask for the event again: duplicates are safe (unique ref), so
      // Razorpay's retry schedule is a free recovery for a transient blip.
      if (pay.error.code !== "23505") {
        console.error(
          "webhook payments insert failed",
          orderId,
          paymentId,
          pay.error,
        );
        return "retry";
      }
      // A row exists for this payment id — which is not the same as this payment
      // being settled. `payment.failed` below writes one, and Razorpay reuses the
      // payment id when such a payment is later authorised and captured. Claim
      // it if it hasn't settled yet; excluding the settled states lets exactly
      // one of this and the app's verify win the race, and stops a late
      // redelivery from re-granting time we have since refunded. See
      // pay/index.ts for the full reasoning — the two must stay in step.
      const claim = await sb.from("payments").update(row)
        .eq("provider", "razorpay").eq("ref", paymentId)
        .neq("status", "success").neq("status", "refunded")
        .select("id");
      if (claim.error) {
        console.error(
          "webhook payments claim failed",
          orderId,
          paymentId,
          claim.error,
        );
        return "retry";
      }
      if (!(claim.data as unknown[] | null)?.length) return "settled";
    }
    const { data: sub } = await sb.from("subscriptions")
      .select("current_period_end").eq("agent_id", ord.agent_id).maybeSingle();
    const base = Math.max(
      Date.now(),
      sub ? new Date(sub.current_period_end).getTime() : 0,
    );
    const newEnd = new Date(base + Number(plan.duration_days) * 86400_000)
      .toISOString();
    const ext = await sb.from("subscriptions").upsert({
      agent_id: ord.agent_id,
      plan_code: plan.code,
      status: "active",
      current_period_end: newEnd,
      updated_at: new Date().toISOString(),
    });
    // Paid, recorded, and NOT activated. A redelivery cannot fix this one — the
    // payment row is already `success`, so the claim above would read it as
    // settled and skip the extension — which is exactly why it must be loud.
    // The 500 is an alarm, not a retry request; the retry it provokes no-ops
    // safely. Grant the days by hand from the agent id and plan logged here.
    if (ext.error) {
      console.error(
        "webhook: subscription not extended",
        orderId,
        paymentId,
        ord.agent_id,
        plan.code,
        ext.error,
      );
      return "stranded";
    }
    return "ok";
  };

  let outcome: Outcome = "ignored";
  try {
    const event = JSON.parse(raw);
    const kind = event?.event;

    if (kind === "payment.captured" || kind === "order.paid") {
      const p = event?.payload?.payment?.entity;
      const orderId = p?.order_id;
      const paymentId = p?.id;
      if (orderId && paymentId) {
        outcome = await activate(String(orderId), String(paymentId));
      }
    } else if (kind === "payment.failed") {
      // Record for dashboard visibility only — never touches subscriptions.
      const p = event?.payload?.payment?.entity;
      if (p?.id) {
        await sb.from("payments").insert({
          agent_id: p?.notes?.agent_id ?? null,
          plan_code: p?.notes?.plan ?? null,
          plan: p?.notes?.plan ?? null,
          // Razorpay reports paise; this column is rupees everywhere else, so
          // writing it raw showed a failed ₹199 attempt as ₹19,900 on the
          // dashboard's payments table.
          amount: typeof p?.amount === "number" ? p.amount / 100 : null,
          currency: "INR",
          provider: "razorpay",
          ref: String(p.id),
          order_id: p?.order_id ?? null,
          status: "failed",
        }); // best-effort; ignore duplicates
      }
    } else if (kind === "refund.created" || kind === "refund.processed") {
      // Mark the original payment refunded. Access is NOT auto-revoked — partial
      // refunds are common and revocation is a business decision. Do it from the
      // dashboard: Plans -> Subscribers -> "End" (or a negative grant), which
      // shortens the subscription and leaves a `manual` row behind.
      const rf = event?.payload?.refund?.entity;
      if (rf?.payment_id) {
        await sb.from("payments").update({ status: "refunded" })
          .eq("provider", "razorpay").eq("ref", String(rf.payment_id));
      }
    }
  } catch (e) {
    // Never make Razorpay retry forever on our own parse error — ack anyway,
    // but don't lose it either.
    console.error("webhook: unhandled event error", e);
  }
  // A transient write failure earns another delivery — duplicates are safe
  // (unique payment ref), so Razorpay's retry schedule is free recovery. A
  // stranded payment earns an alarm. Everything else is 200, so a handled or
  // duplicate event isn't retried endlessly.
  const status = outcome === "retry" || outcome === "stranded" ? 500 : 200;
  return new Response(JSON.stringify({ ok: status === 200, outcome }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
});
