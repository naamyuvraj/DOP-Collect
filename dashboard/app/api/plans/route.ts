import { NextRequest, NextResponse } from "next/server";
import { unstable_cache, revalidateTag } from "next/cache";
import { isAuthed } from "@/lib/auth";
import { admin } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// Cache the (read-only) plans payload for 30s so repeat visits are instant
// instead of a fresh ~0.5s Supabase round-trip. Every write busts the tag
// below, so edits still show immediately. Data is not per-user (single admin).
const readPlans = unstable_cache(
  async () => {
    const sb = admin();
    const [plans, cfg, subs, mrr] = await Promise.all([
      sb.from("plans").select("*").order("sort"),
      sb.from("app_config").select("key,value").in("key", ["payments_enabled", "trial_days"]),
      sb.from("v_subscriptions").select("*").limit(500),
      sb.from("v_mrr").select("*"),
    ]);
    const config: Record<string, unknown> = {};
    for (const row of cfg.data || []) config[(row as any).key] = (row as any).value;
    return {
      plans: plans.data || [],
      config: { payments_enabled: config.payments_enabled ?? false, trial_days: config.trial_days ?? 14 },
      subscribers: subs.data || [],
      mrr: mrr.data || [],
      error: plans.error?.message,
    };
  },
  ["plans-data"],
  { revalidate: 30, tags: ["plans"] }
);

// Plans & subscription rollout control.
// ---------------------------------------------------------------------------
// The app reads plans live (via the `pay` edge function's `status` action, which
// selects from this same `plans` table), so editing a plan here changes what
// every install is offered WITHOUT an app update. Rollout control:
//   - payments_enabled (app_config): master kill switch for the whole paywall.
//   - plans.active: per-plan on/off — hide/show a tier to all users instantly.
//   - trial_days (app_config): default free-trial length.
// All writes use the service_role key, server-side only.

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

// GET -> { plans, config:{payments_enabled,trial_days}, subscribers[], mrr[] }
export async function GET() {
  const bad = guard();
  if (bad) return bad;
  try {
    return NextResponse.json(await readPlans());
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 500 });
  }
}

// POST -> create a plan
export async function POST(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const b = await req.json().catch(() => ({}));
  const code = String(b.code || "").trim().toLowerCase();
  if (!code) return NextResponse.json({ ok: false, error: "code is required" }, { status: 400 });
  const { error } = await admin().from("plans").insert({
    code,
    name: b.name || code,
    price_inr: Number(b.price_inr) || 0,
    duration_days: Number(b.duration_days) || 30,
    active: b.active !== false,
    sort: Number(b.sort) || 0,
  });
  if (!error) revalidateTag("plans");
  return NextResponse.json({ ok: !error, error: error?.message });
}

// PATCH -> update a plan by code (name/price/duration/active/sort)
export async function PATCH(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const b = await req.json().catch(() => ({}));
  const code = String(b.code || "").trim();
  if (!code) return NextResponse.json({ ok: false, error: "code is required" }, { status: 400 });
  const patch: Record<string, unknown> = {};
  if (b.name !== undefined) patch.name = String(b.name);
  if (b.price_inr !== undefined) patch.price_inr = Number(b.price_inr) || 0;
  if (b.duration_days !== undefined) patch.duration_days = Number(b.duration_days) || 0;
  if (b.active !== undefined) patch.active = !!b.active;
  if (b.sort !== undefined) patch.sort = Number(b.sort) || 0;
  if (!Object.keys(patch).length)
    return NextResponse.json({ ok: false, error: "nothing to update" }, { status: 400 });
  const { error } = await admin().from("plans").update(patch).eq("code", code);
  if (!error) revalidateTag("plans");
  return NextResponse.json({ ok: !error, error: error?.message });
}

// DELETE -> remove a plan by code (blocked by FK if any subscription references it)
export async function DELETE(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const b = await req.json().catch(() => ({}));
  const code = String(b.code || "").trim();
  if (!code) return NextResponse.json({ ok: false, error: "code is required" }, { status: 400 });
  const { error } = await admin().from("plans").delete().eq("code", code);
  if (!error) revalidateTag("plans");
  return NextResponse.json({
    ok: !error,
    error: error?.message
      ? `${error.message}. If this plan has subscribers, deactivate it instead of deleting.`
      : undefined,
  });
}

// PUT -> set a rollout control flag in app_config (payments_enabled | trial_days)
export async function PUT(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const { key, value } = await req.json().catch(() => ({}));
  if (key !== "payments_enabled" && key !== "trial_days")
    return NextResponse.json({ ok: false, error: "unknown config key" }, { status: 400 });
  const { error } = await admin()
    .from("app_config")
    .upsert({ key, value, updated_at: new Date().toISOString() });
  if (!error) revalidateTag("plans");
  return NextResponse.json({ ok: !error, error: error?.message });
}
