import { admin, dbConfigured } from "./supabase";
import { solOf } from "./agentId";

// Single source of truth for AGENT-LEVEL metrics. Both the Users tab and the
// Overview read this, so every number agrees. The unit is the AGENT (a real DOP
// person), not the install: an agent on 4 phones is one agent, and their book
// (accounts / value) is counted once. Anonymous installs (app opened, never
// onboarded/verified) are kept as rows but excluded from the "agents" count.

export type UserRow = {
  device_id: string;
  device_ids: string[];
  devices: number;
  name: string | null;
  mobile: string | null;
  agent_name: string | null;
  agent_id: string | null;
  region: string | null;
  accounts: number | null;
  value: number | null;
  collected: number;
  plan: string | null;
  sub_status: string | null;
  phone_verified: boolean;
  onboarded: boolean; // has a real identity (agent id / verified / synced / named)
  app_version: string | null;
  first_seen: string | null;
  last_seen: string | null;
  active: boolean;
};

export type UsersTotals = {
  agents: number; // real agents (onboarded) — the headline unit
  verified: number; // agents verified by WhatsApp OTP
  active: number; // agents active in the last 7 days
  installs: number; // phones/app installs seen
  accounts: number; // RD accounts under management (deduped per agent)
  value: number; // ₹ deposited across all books (assets under management)
  collected: number; // ₹ submitted to the post office (list_submitted)
  lists: number; // submitted lists
  subscribers: number; // paying/active subscriptions
  ai_queries: number; // assistant questions asked
};

export type UsersData = { rows: UserRow[]; totals: UsersTotals; region_labels: Record<string, string> };

export async function computeUsers(): Promise<UsersData> {
  const empty: UsersTotals = { agents: 0, verified: 0, active: 0, installs: 0, accounts: 0, value: 0, collected: 0, lists: 0, subscribers: 0, ai_queries: 0 };
  if (!dbConfigured()) return { rows: [], totals: empty, region_labels: {} };
  const sb = admin();

  const [baseRes, devRes, subRes, syncRes, submitRes, cfgRes, sessRes, acctRes, aiRes] = await Promise.all([
    sb.from("v_devices").select("*"),
    sb.from("devices").select("*"),
    sb.from("v_subscriptions").select("agent_id,plan_name,plan_code,status"),
    sb.from("events").select("device_id,props,created_at").eq("event", "sync_done").order("created_at", { ascending: false }).limit(5000),
    sb.from("events").select("device_id,props").eq("event", "list_submitted").limit(5000),
    sb.from("app_config").select("value").eq("key", "region_labels").maybeSingle(),
    sb.from("device_sessions").select("device_id,account_id,revoked_at"),
    sb.from("accounts").select("id,agent_id"),
    sb.from("events").select("id", { count: "exact", head: true }).eq("event", "assistant_query"),
  ]);

  const base = (baseRes.error ? (devRes.data as any[]) : (baseRes.data as any[])) || [];
  const extra = new Map<string, any>(((devRes.data as any[]) || []).map((d) => [String(d.id), d]));
  const subs = (subRes.data as any[]) || [];
  const syncs = (syncRes.data as any[]) || [];
  const submits = (submitRes.data as any[]) || [];

  const acctToAgent = new Map<string, string>();
  for (const a of (acctRes.data as any[]) || []) if (a.id && a.agent_id) acctToAgent.set(a.id, a.agent_id);

  const sessByDevice = new Map<string, { account_id: string | null; verified: boolean }>();
  for (const s of (sessRes.data as any[]) || []) {
    const cur = sessByDevice.get(s.device_id);
    const active = !s.revoked_at;
    if (!cur || active) sessByDevice.set(s.device_id, { account_id: s.account_id ?? cur?.account_id ?? null, verified: active || !!cur?.verified });
  }

  const accByDevice = new Map<string, number>();
  const valueByDevice = new Map<string, number>();
  const seenSync = new Set<string>();
  for (const e of syncs) {
    if (seenSync.has(e.device_id)) continue;
    seenSync.add(e.device_id);
    const n = Number(e.props?.accounts);
    if (Number.isFinite(n) && n >= 0) accByDevice.set(e.device_id, n);
    const v = Number(e.props?.total_amount);
    if (Number.isFinite(v) && v >= 0) valueByDevice.set(e.device_id, v);
  }
  const collByDevice = new Map<string, number>();
  for (const e of submits) collByDevice.set(e.device_id, (collByDevice.get(e.device_id) || 0) + (Number(e.props?.amount) || 0));

  const subByAgent = new Map<string, { plan: string | null; status: string | null }>();
  for (const s of subs) subByAgent.set(s.agent_id, { plan: s.plan_name ?? s.plan_code ?? null, status: s.status ?? null });

  const weekAgo = Date.now() - 7 * 864e5;
  const perDevice = base.map((b) => {
    const id = String(b.id);
    const x = extra.get(id) || {};
    const sess = sessByDevice.get(id);
    const accountId = sess?.account_id || x.account_id || null;
    const agentId = x.agent_id || (accountId ? acctToAgent.get(accountId) || null : null);
    return {
      id,
      account_id: accountId,
      agentId,
      name: x.name || null,
      mobile: x.mobile || null,
      agent_name: b.agent_name || null,
      sol_id: x.sol_id || (agentId ? solOf(agentId) || null : null),
      accounts: accByDevice.has(id) ? accByDevice.get(id)! : null,
      value: valueByDevice.has(id) ? valueByDevice.get(id)! : null,
      collected: collByDevice.get(id) || 0,
      phone_verified: !!x.phone_verified || !!sess?.verified,
      app_version: b.app_version || null,
      first_seen: b.first_seen || null,
      last_seen: b.last_seen || null,
    };
  });

  const groupKey = (d: (typeof perDevice)[number]) =>
    d.agentId ? `id:${d.agentId}` : d.account_id ? `acc:${d.account_id}` : d.agent_name ? `nm:${d.agent_name.toLowerCase()}` : `dev:${d.id}`;
  const groups = new Map<string, (typeof perDevice)[number][]>();
  for (const d of perDevice) {
    const k = groupKey(d);
    (groups.get(k) || groups.set(k, []).get(k)!).push(d);
  }

  const pick = <T,>(ds: any[], f: (d: any) => T): T | null => { for (const d of ds) { const v = f(d); if (v != null && v !== "") return v; } return null; };
  const rows: UserRow[] = [...groups.values()].map((ds) => {
    const byRecent = [...ds].sort((a, b) => (a.last_seen || "") < (b.last_seen || "") ? 1 : -1);
    const agentId = pick(byRecent, (d) => d.agentId);
    const sub = agentId ? subByAgent.get(agentId) : undefined;
    const accVals = ds.map((d) => d.accounts).filter((v): v is number => v != null);
    const valVals = ds.map((d) => d.value).filter((v): v is number => v != null);
    const lastSeen = pick(byRecent, (d) => d.last_seen);
    const verified = ds.some((d) => d.phone_verified);
    const accounts = accVals.length ? Math.max(...accVals) : null;
    const agent_name = pick(byRecent, (d) => d.agent_name);
    return {
      device_id: byRecent[0].id,
      device_ids: ds.map((d) => d.id),
      devices: ds.length,
      name: pick(byRecent, (d) => d.name),
      mobile: pick(byRecent, (d) => d.mobile),
      agent_name,
      agent_id: agentId,
      region: pick(byRecent, (d) => d.sol_id),
      accounts,
      value: valVals.length ? Math.max(...valVals) : null,
      collected: ds.reduce((s, d) => s + d.collected, 0),
      plan: sub?.plan ?? null,
      sub_status: sub?.status ?? null,
      phone_verified: verified,
      // "Onboarded" = a real agent (not just an app-open): has an agent id, is
      // verified, has synced a book, or at least typed an agent name.
      onboarded: !!agentId || verified || accounts != null || !!agent_name,
      app_version: byRecent[0].app_version,
      first_seen: ds.reduce<string | null>((m, d) => (!m || (d.first_seen && d.first_seen < m) ? d.first_seen : m), null),
      last_seen: lastSeen,
      active: !!lastSeen && new Date(lastSeen).getTime() >= weekAgo,
    };
  });
  rows.sort((a, b) => (a.last_seen || "") < (b.last_seen || "") ? 1 : -1);

  const agents = rows.filter((r) => r.onboarded);
  const totals: UsersTotals = {
    agents: agents.length,
    verified: rows.filter((r) => r.phone_verified).length,
    active: agents.filter((r) => r.active).length,
    installs: perDevice.length,
    accounts: rows.reduce((s, r) => s + (r.accounts || 0), 0),
    value: rows.reduce((s, r) => s + (r.value || 0), 0),
    collected: rows.reduce((s, r) => s + r.collected, 0),
    lists: submits.length,
    subscribers: rows.filter((r) => r.sub_status && r.sub_status !== "expired").length,
    ai_queries: (aiRes as any).count ?? 0,
  };

  return { rows, totals, region_labels: (cfgRes.data?.value as Record<string, string>) || {} };
}
