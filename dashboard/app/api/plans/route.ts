import { NextRequest, NextResponse } from "next/server";
import { unstable_cache, revalidateTag } from "next/cache";
import { isAuthed } from "@/lib/auth";
import { admin } from "@/lib/supabase";

export const dynamic = "force-dynamic";

const loadPlansData = async () => {
  const sb = admin();
  const [plans, cfg, subs, mrr, devs] = await Promise.all([
    sb.from("plans").select("*").order("sort"),
    sb.from("app_config").select("key,value").in("key", ["payments_enabled", "trial_days"]),
    sb.from("v_subscriptions").select("*").limit(500),
    sb.from("v_mrr").select("*"),
    // v_subscriptions carries agent_id and no name, so the Subscribers table
    // could only show "DOP.MI8472350100005" — unidentifiable without going to
    // the Users tab and matching by eye. Resolve the name here.
    sb.from("devices").select("agent_id,agent_name"),
  ]);
  const nameByAgent = new Map<string, string>();
  for (const d of (devs.data as any[]) || []) {
    if (d.agent_id && d.agent_name) nameByAgent.set(d.agent_id, d.agent_name);
  }
  const config: Record<string, unknown> = {};
  for (const row of cfg.data || []) config[(row as any).key] = (row as any).value;
  return {
    plans: plans.data || [],
    config: { payments_enabled: config.payments_enabled ?? false, trial_days: config.trial_days ?? 14 },
    subscribers: ((subs.data as any[]) || []).map((r) => ({
      ...r,
      agent_name: nameByAgent.get(r.agent_id) ?? null,
    })),
    mrr: mrr.data || [],
    error: plans.error?.message,
  };
};

// Cache the (read-only) plans payload for 30s so repeat visits are instant
// instead of a fresh ~0.5s Supabase round-trip. Every write busts the tag
// below. Data is not per-user (single admin).
const readPlans = unstable_cache(loadPlansData, ["plans-data"], {
  revalidate: 30,
  tags: ["plans"],
});

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
//
// `?fresh=1` skips the 30s cache and reads Supabase directly. Used for the
// refetch straight after a write: `revalidateTag` marks the entry stale, but the
// write and the read can land on different serverless instances, so a refetch
// milliseconds later could still be served the pre-write payload — which showed
// the operator KPI cards that hadn't moved and made a change that DID land look
// like it hadn't. A read-your-own-write must not depend on that timing.
export async function GET(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const fresh = req.nextUrl.searchParams.get("fresh") === "1";
    return NextResponse.json(fresh ? await loadPlansData() : await readPlans());
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
