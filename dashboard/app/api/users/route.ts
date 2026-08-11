import { NextResponse } from "next/server";
import { unstable_cache } from "next/cache";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";
import { solOf } from "@/lib/agentId";

export const dynamic = "force-dynamic";

// One joined row per install for the Users tab: identity (name/agent/region),
// the size of their book (accounts + collected sum), and their plan. Joined
// server-side from devices + telemetry + subscriptions; the browser only sees
// the finished rows. Cached 60s (read-only). NOTE: the raw mobile number is
// never stored (OTP keeps only a hash) — we expose phone_verified instead.

export type UserRow = {
  device_id: string;
  name: string | null;
  mobile: string | null;
  agent_name: string | null;
  agent_id: string | null;
  region: string | null; // SOL ID (post-office branch)
  accounts: number | null;
  collected: number;
  plan: string | null;
  sub_status: string | null;
  phone_verified: boolean;
  app_version: string | null;
  first_seen: string | null;
  last_seen: string | null;
  active: boolean;
};

const readUsers = unstable_cache(
  async () => {
    const sb = admin();
    // Base on v_devices (devices ∪ everyone who sent events) so an agent who
    // synced but whose identify() upsert never landed is NOT dropped. Merge the
    // extra identity columns (agent_id/sol_id/phone_verified/name) from devices.
    const [baseRes, devRes, subRes, syncRes, submitRes, cfgRes] = await Promise.all([
      sb.from("v_devices").select("*"),
      // select("*") so a not-yet-migrated column (e.g. mobile) can't error the
      // whole query and wipe out agent_id/sol_id/name/phone_verified.
      sb.from("devices").select("*"),
      sb.from("v_subscriptions").select("agent_id,plan_name,plan_code,status"),
      sb.from("events").select("device_id,props,created_at").eq("event", "sync_done").order("created_at", { ascending: false }).limit(5000),
      sb.from("events").select("device_id,props").eq("event", "list_submitted").limit(5000),
      sb.from("app_config").select("value").eq("key", "region_labels").maybeSingle(),
    ]);
    const base = (baseRes.error ? (devRes.data as any[]) : (baseRes.data as any[])) || [];
    const extra = new Map<string, any>(((devRes.data as any[]) || []).map((d) => [String(d.id), d]));
    const subs = (subRes.data as any[]) || [];
    const syncs = (syncRes.data as any[]) || [];
    const submits = (submitRes.data as any[]) || [];

    // Latest account count per device (rows are newest-first).
    const accByDevice = new Map<string, number>();
    for (const e of syncs) {
      if (accByDevice.has(e.device_id)) continue;
      const n = Number(e.props?.accounts);
      if (Number.isFinite(n) && n >= 0) accByDevice.set(e.device_id, n);
    }
    // Collected sum per device (submitted lots).
    const collByDevice = new Map<string, number>();
    for (const e of submits) {
      const n = Number(e.props?.amount) || 0;
      collByDevice.set(e.device_id, (collByDevice.get(e.device_id) || 0) + n);
    }
    // Subscription by agent_id.
    const subByAgent = new Map<string, { plan: string | null; status: string | null }>();
    for (const s of subs) subByAgent.set(s.agent_id, { plan: s.plan_name ?? s.plan_code ?? null, status: s.status ?? null });

    const weekAgo = Date.now() - 7 * 864e5;
    const rows: UserRow[] = base.map((b) => {
      const id = String(b.id);
      const x = extra.get(id) || {};
      const agentId = x.agent_id || null;
      const sub = agentId ? subByAgent.get(agentId) : undefined;
      return {
        device_id: id,
        name: x.name || null,
        mobile: x.mobile || null,
        agent_name: b.agent_name || null,
        agent_id: agentId,
        region: x.sol_id || (agentId ? solOf(agentId) || null : null),
        accounts: accByDevice.has(id) ? accByDevice.get(id)! : null,
        collected: collByDevice.get(id) || 0,
        plan: sub?.plan ?? null,
        sub_status: sub?.status ?? null,
        phone_verified: !!x.phone_verified,
        app_version: b.app_version || null,
        first_seen: b.first_seen || null,
        last_seen: b.last_seen || null,
        active: !!b.last_seen && new Date(b.last_seen).getTime() >= weekAgo,
      };
    });

    // Sort by most recently seen by default.
    rows.sort((a, b) => (a.last_seen || "") < (b.last_seen || "") ? 1 : -1);

    const totals = {
      users: rows.length,
      accounts: rows.reduce((s, r) => s + (r.accounts || 0), 0),
      collected: rows.reduce((s, r) => s + r.collected, 0),
      active: rows.filter((r) => r.active).length,
      subscribers: rows.filter((r) => r.sub_status && r.sub_status !== "expired").length,
    };
    const region_labels = (cfgRes.data?.value as Record<string, string>) || {};
    return { rows, totals, region_labels };
  },
  ["users-data"],
  { revalidate: 60, tags: ["users"] }
);

export async function GET() {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!dbConfigured()) return NextResponse.json({ rows: [], totals: {} });
  try {
    return NextResponse.json(await readUsers());
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 500 });
  }
}
