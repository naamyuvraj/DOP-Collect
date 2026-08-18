import { NextResponse } from "next/server";
import { unstable_cache } from "next/cache";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";
import { parseAgentId } from "@/lib/agentId";
import { isPaying, paidPlanCodes, type PlanLike } from "@/lib/subs";

export const dynamic = "force-dynamic";

// Regions = installs/subscribers grouped by SOL ID (the post-office branch code
// inside every DOP agent id: MI + <SOL ID> + 5-digit seq). Sources:
//   - devices.sol_id / devices.agent_id  (populated once the app is updated)
//   - subscriptions.agent_id             (works today — the paying agents)
// The service_role key stays server-side; the browser only sees aggregates.

type Region = {
  sol_id: string;
  installs: number;
  active_installs: number;
  subscribers: number;
  agents: number;
  last_seen?: string;
};

// Read-only; telemetry changes slowly, so a 60s cache makes repeat visits
// instant. (No mutation endpoints here, so no tag-busting needed.)
const readRegions = unstable_cache(
  async () => {
    const sb = admin();
    // select("*") on devices so missing agent_id/sol_id columns don't error.
    const [devRes, subRes, planRes] = await Promise.all([
      sb.from("devices").select("*"),
      sb.from("subscriptions").select("agent_id,plan_code,status,current_period_end"),
      sb.from("plans").select("code,price_inr"),
    ]);
    const devices = (devRes.data as any[]) || [];
    const subs = (subRes.data as any[]) || [];
    // This counted every subscriptions row, so a free trial and a ₹0 manual
    // grant both read as "subscribers" here while Overview called them 0.
    // Price decides it now, same as every other tab — see lib/subs.ts.
    const paidCodes = paidPlanCodes((planRes.data as PlanLike[]) || []);

    const map = new Map<string, Region & { _agents: Set<string> }>();
    const bump = (sol: string) => {
      let r = map.get(sol);
      if (!r) {
        r = { sol_id: sol, installs: 0, active_installs: 0, subscribers: 0, agents: 0, _agents: new Set() };
        map.set(sol, r);
      }
      return r;
    };

    let anonymousInstalls = 0;
    let invalidIds = 0;
    const weekAgo = Date.now() - 7 * 864e5;

    for (const d of devices) {
      // Prefer an explicit sol_id column; else derive from a stored agent_id.
      let sol = (d.sol_id || "").toString();
      if (!sol && d.agent_id) {
        const p = parseAgentId(d.agent_id);
        if (p.valid) sol = p.solId;
        else invalidIds++;
      }
      if (!sol) {
        anonymousInstalls++;
        continue;
      }
      const r = bump(sol);
      r.installs++;
      if (d.last_seen && new Date(d.last_seen).getTime() >= weekAgo) r.active_installs++;
      if (d.agent_id) r._agents.add(d.agent_id);
      if (!r.last_seen || (d.last_seen && d.last_seen > r.last_seen)) r.last_seen = d.last_seen;
    }

    for (const s of subs) {
      const p = parseAgentId(s.agent_id);
      if (!p.valid) {
        invalidIds++;
        continue;
      }
      const r = bump(p.solId);
      if (isPaying(s, paidCodes)) r.subscribers++;
      // Still an agent of this branch even on a free trial — only the paying
      // count is narrowed.
      r._agents.add(s.agent_id);
    }

    const regions = [...map.values()]
      .map(({ _agents, ...r }) => ({ ...r, agents: Math.max(r.agents, _agents.size) }))
      .sort((a, b) => b.installs + b.subscribers - (a.installs + a.subscribers));

    return {
      regions,
      totals: {
        regions: regions.length,
        installs: devices.length,
        installs_with_region: devices.length - anonymousInstalls,
        anonymous_installs: anonymousInstalls,
        // Paying rows, not every row — this said 2 while Overview said 0 for
        // the same two agents, both of whom were on a free trial.
        subscribers: subs.filter((s) => isPaying(s, paidCodes)).length,
        invalid_ids: invalidIds,
      },
      // True once devices carry sol_id/agent_id (app updated). Drives the hint.
      device_region_ready: devices.some((d) => d.sol_id || d.agent_id),
    };
  },
  ["regions-data"],
  { revalidate: 60, tags: ["regions"] }
);

export async function GET() {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!dbConfigured()) return NextResponse.json({ regions: [], totals: {} });
  try {
    return NextResponse.json(await readRegions());
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 500 });
  }
}
