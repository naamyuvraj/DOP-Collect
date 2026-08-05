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
    "raw", new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const s = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(s)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// Same activation as pay/verify — plan + agent from the recorded order.
async function activate(sb: ReturnType<typeof createClient>, orderId: string, paymentId: string) {
  const { data: ord } = await sb
    .from("orders").select("agent_id, plan_code").eq("order_id", orderId).maybeSingle();
  if (!ord) return;
  const { data: plan } = await sb
    .from("plans").select("code, price_inr, duration_days").eq("code", ord.plan_code).maybeSingle();
  if (!plan) return;
  const pay = await sb.from("payments").insert({
    agent_id: ord.agent_id, plan_code: plan.code, amount: plan.price_inr,
    currency: "INR", provider: "razorpay", ref: paymentId, order_id: orderId,
    status: "success", plan: plan.code,
  });
  if (pay.error) return; // already processed (unique ref) — no double extend
  const { data: sub } = await sb.from("subscriptions")
    .select("current_period_end").eq("agent_id", ord.agent_id).maybeSingle();
  const base = Math.max(Date.now(), sub ? new Date(sub.current_period_end).getTime() : 0);
  const newEnd = new Date(base + Number(plan.duration_days) * 86400_000).toISOString();
  await sb.from("subscriptions").upsert({
    agent_id: ord.agent_id, plan_code: plan.code, status: "active",
    current_period_end: newEnd, updated_at: new Date().toISOString(),
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const raw = await req.text();
  const secret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET") || "";
  const sig = req.headers.get("x-razorpay-signature") || "";
  if (!secret || !timingSafeEqual(await hmacHex(secret, raw), sig))
    return new Response("invalid signature", { status: 400 });

  try {
    const event = JSON.parse(raw);
    if (event?.event === "payment.captured" || event?.event === "order.paid") {
      const p = event?.payload?.payment?.entity;
      const orderId = p?.order_id;
      const paymentId = p?.id;
      if (orderId && paymentId) {
        const sb = createClient(
          Deno.env.get("SUPABASE_URL")!,
          Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
        );
        await activate(sb, String(orderId), String(paymentId));
      }
    }
  } catch (_) {
    // Never make Razorpay retry forever on our parse error — ack anyway.
  }
  // Always 200 so a handled/duplicate event isn't retried endlessly.
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
