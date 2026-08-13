import { NextRequest, NextResponse } from "next/server";
import { revalidateTag } from "next/cache";
import { isAuthed } from "@/lib/auth";
import { admin } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// Subscription repair — the manual counterpart to the `pay` edge function.
// ---------------------------------------------------------------------------
// Activation is server-authoritative and idempotent, but it can still end with
// money taken and access not granted: the payment row lands and the
// subscription upsert fails (`activate_failed` in pay/verify, `stranded` in the
// webhook). That state cannot self-heal — the payment id is already recorded, so
// a replay reads it as settled and skips the extension — so it needs a human.
// Until now there was no way to be that human: the dashboard could only READ
// subscriptions, which also left the webhook's refund note ("shorten the
// subscription from the dashboard") pointing at a control that didn't exist.
//
// Every adjustment writes a `payments` row with provider/status `manual`, so a
// granted day is never invisible. Those rows are excluded from revenue by
// construction: v_summary and v_mrr both count `status = 'success'` only.
//
// All writes use the service_role key, server-side only, behind the same
// dashboard auth as every other route here.

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

const bad = (error: string) => NextResponse.json({ ok: false, error }, { status: 400 });

/** Guard rails on a hand-typed number: no 10-year grants from a stray keypress. */
const MAX_DAYS = 400;

// PATCH -> adjust one agent's access.
//   { agentId, addDays: 30 }      grant 30 days (stacks, like a real purchase)
//   { agentId, addDays: -30 }     take 30 days back
//   { agentId, endNow: true }     end access now (e.g. after a full refund)
//   { agentId, planCode: "m1" }   also label the subscription with a plan
export async function PATCH(req: NextRequest) {
  const unauth = guard();
  if (unauth) return unauth;

  const b = await req.json().catch(() => ({}));
  const agentId = String(b.agentId || "").trim();
  if (!agentId) return bad("agentId is required");

  const endNow = b.endNow === true;
  const addDays = b.addDays === undefined ? 0 : Number(b.addDays);
  if (!endNow) {
    if (!Number.isFinite(addDays) || addDays === 0)
      return bad("addDays must be a non-zero number, or pass endNow");
    if (Math.abs(addDays) > MAX_DAYS)
      return bad(`addDays must be within ±${MAX_DAYS}`);
  }

  const sb = admin();
  const { data: sub, error: readErr } = await sb
    .from("subscriptions")
    .select("plan_code, current_period_end")
    .eq("agent_id", agentId)
    .maybeSingle();
  if (readErr) return NextResponse.json({ ok: false, error: readErr.message }, { status: 500 });

  // Same stacking rule the edge functions use, so a manual grant behaves exactly
  // like the purchase it is standing in for: time already paid for is never
  // burned, but an expired plan restarts from today rather than from its old end.
  const current = sub?.current_period_end ? new Date(sub.current_period_end).getTime() : 0;
  const base = Math.max(Date.now(), current);
  const end = endNow ? new Date() : new Date(base + addDays * 86400_000);

  const planCode = b.planCode ? String(b.planCode) : sub?.plan_code ?? null;
  const { error } = await sb.from("subscriptions").upsert({
    agent_id: agentId,
    plan_code: planCode,
    status: end.getTime() > Date.now() ? "active" : "expired",
    current_period_end: end.toISOString(),
    updated_at: new Date().toISOString(),
  });
  if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 500 });

  // Leave a trail. Best-effort: the access change is what matters and has
  // already happened, so a failed note must not report the whole thing failed.
  const note = endNow ? "ended manually" : `${addDays > 0 ? "+" : ""}${addDays} days`;
  const trail = await sb.from("payments").insert({
    agent_id: agentId,
    plan_code: planCode,
    plan: planCode,
    amount: 0,
    currency: "INR",
    provider: "manual",
    status: "manual",
    ref: `manual_${Date.now()}_${agentId}`,
  });
  if (trail.error) console.error("subscription adjusted but not logged", agentId, note, trail.error);

  revalidateTag("plans");
  return NextResponse.json({
    ok: true,
    agentId,
    note,
    periodEnd: end.toISOString(),
    logged: !trail.error,
  });
}
