import { admin, dbConfigured } from "./supabase";
import { solOf } from "./agentId";
import { isPaying, paidPlanCodes, type PlanLike } from "./subs";

// Single source of truth for AGENT-LEVEL metrics. Both the Users tab and the
// Overview read this, so every number agrees. The unit is the AGENT (a real DOP
// person), not the install: an agent on 4 phones is one agent, and their book
// (accounts / value) is counted once. Anonymous installs (app opened, never
// onboarded/verified) are kept as rows but excluded from the "agents" count.

/** One physical phone under an agent, for the drawer's per-phone list. */
export type PhoneRow = {
  id: string;
  /** Handset, e.g. "Redmi Note 12". Null for installs older than 0.9.51. */
  model: string | null;
  app_version: string | null;
  last_seen: string | null;
  /** True when this phone holds a live session right now. */
  signed_in: boolean;
};

export type UserRow = {
  device_id: string;
  device_ids: string[];
  /** Every phone in this group, newest-seen first. */
  phones: PhoneRow[];
  /** Distinct device ids ever seen for this agent. Never decreases. */
  devices: number;
  /** Installs with a LIVE session right now. This is "how many phones is he on". */
  signed_in: number;
  /**
   * The agent's ONE name, from `devices.agent_name`. Onboarding used to capture
   * two ("Name" for display and "Agent Name" for the DOP paperwork) into two
   * columns; agents filled either or both, so neither could be trusted alone.
   * `devices.name` has since been dropped — see admin/schema_one_name.sql.
   */
  name: string | null;
  mobile: string | null;
  agent_id: string | null;
  /** Handset, e.g. "Redmi Note 12". Null for installs older than 0.9.51. */
  model: string | null;
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
  /**
   * The active MONTHLY RD book: sum of every account's monthly installment,
   * in ₹/month. NOT cumulative deposits — that figure is roughly 20-30x larger.
   * The app computes it as sum(denominationAmount) and sends it as
   * `sync_done.total_amount`; the UI labels it "Monthly book".
   *
   * The old comment here read "₹ deposited across all books (assets under
   * management)", which describes a completely different and much bigger number.
   */
  value: number;
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

  const [baseRes, devRes, subRes, syncRes, submitRes, cfgRes, sessRes, acctRes, aiRes, payCfgRes, planRes] = await Promise.all([
    sb.from("v_devices").select("*"),
    sb.from("devices").select("*"),
    sb.from("v_subscriptions").select("agent_id,plan_name,plan_code,status"),
    sb.from("events").select("device_id,props,created_at").eq("event", "sync_done").order("created_at", { ascending: false }).limit(5000),
    sb.from("events").select("device_id,props").eq("event", "list_submitted").limit(5000),
    sb.from("app_config").select("value").eq("key", "region_labels").maybeSingle(),
    sb.from("device_sessions").select("device_id,account_id,revoked_at"),
    sb.from("accounts").select("id,agent_id"),
    sb.from("events").select("id", { count: "exact", head: true }).eq("event", "assistant_query"),
    sb.from("app_config").select("key,value").in("key", ["payments_enabled", "trial_days"]),
    // Every plan, not just the trial: `subscribers` is decided on price now, so
    // it needs to know which codes actually charge.
    sb.from("plans").select("code,name,price_inr,duration_days"),
  ]);

  const base = (baseRes.error ? (devRes.data as any[]) : (baseRes.data as any[])) || [];
  const extra = new Map<string, any>(((devRes.data as any[]) || []).map((d) => [String(d.id), d]));
  const subs = (subRes.data as any[]) || [];
  const syncs = (syncRes.data as any[]) || [];
  const submits = (submitRes.data as any[]) || [];

  const acctToAgent = new Map<string, string>();
  for (const a of (acctRes.data as any[]) || []) if (a.id && a.agent_id) acctToAgent.set(a.id, a.agent_id);

  const sessByDevice =
    new Map<string, { account_id: string | null; verified: boolean; live: boolean }>();
  for (const s of (sessRes.data as any[]) || []) {
    const cur = sessByDevice.get(s.device_id);
    const active = !s.revoked_at;
    if (!cur || active) {
      sessByDevice.set(s.device_id, {
        account_id: s.account_id ?? cur?.account_id ?? null,
        verified: active || !!cur?.verified,
        live: active || !!cur?.live,
      });
    }
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

  // While `payments_enabled` is OFF, `pay`'s resolve() hands the app a trial but
  // deliberately writes NO subscriptions row (see supabase/functions/pay/index.ts
  // and admin/backfill_trials.sql — a row per agent id that ever opens the app
  // would be trial-row spam). So the table is empty for every new agent, and
  // reading it alone made the drawer say "No record yet" while the phone in the
  // agent's hand said "Free trial". Mirror the same rule here so the dashboard
  // reports what the agent is actually experiencing.
  //
  // Deliberately NOT persisted: this stays a read-time derivation, so the moment
  // payments are switched on the real rows take over and the backfill's
  // "existing agents have had their go" logic is untouched.
  const payCfg = new Map<string, unknown>(
    ((payCfgRes.data as any[]) || []).map((r) => [r.key, r.value])
  );
  const paymentsEnabled = payCfg.get("payments_enabled") === true;
  const allPlans = ((planRes.data as PlanLike[]) || []);
  const paidCodes = paidPlanCodes(allPlans);
  const trialPlan =
    (allPlans as { code: string; name?: string; duration_days?: number }[])
      .find((p) => p.code === "trial") ?? null;
  const trialName = trialPlan?.name ?? "Free trial";

  // `code` is kept alongside the display name because "is this a subscriber?"
  // cannot be answered from plan_name or status alone — a live trial is stored
  // status 'active', so counting non-expired rows counted trialists as paying.
  //
  // A row with NO plan_code resolves to the trial too. Such a row is written by
  // the Fix-access grants (app/api/subscriptions/route.ts), and reading it
  // literally showed an agent with 60 days of access as plan "—" — the one
  // agent on this dashboard who looked like they had no trial was on one.
  // An agent with no row at all already falls through to `ephemeralTrial`
  // below, so both shapes of "free access" now say the same thing.
  const subByAgent = new Map<
    string,
    { plan: string | null; code: string | null; status: string | null }
  >();
  for (const s of subs) {
    const code = s.plan_code ?? "trial";
    subByAgent.set(s.agent_id, {
      plan: s.plan_name ?? (code === "trial" ? trialName : code),
      code,
      status: s.status ?? null,
    });
  }

  const ephemeralTrial = {
    plan: trialName,
    code: "trial",
    status: "trial" as const,
  };

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
      // One name, one column. `devices.name` no longer exists.
      name: b.agent_name || x.agent_name || null,
      mobile: x.mobile || null,
      model: x.model || null,
      sol_id: x.sol_id || (agentId ? solOf(agentId) || null : null),
      accounts: accByDevice.has(id) ? accByDevice.get(id)! : null,
      value: valueByDevice.has(id) ? valueByDevice.get(id)! : null,
      collected: collByDevice.get(id) || 0,
      phone_verified: !!x.phone_verified || !!sess?.verified,
      session_live: !!sess?.live,
      app_version: b.app_version || null,
      first_seen: b.first_seen || null,
      last_seen: b.last_seen || null,
    };
  });

  // Group a person's phones together — TRANSITIVELY.
  //
  // This used to pick ONE key per device (agent id, else account id, else name)
  // and bucket on it. Identity is not that tidy: the same agent shows up as two
  // rows the moment one phone carries an agent_id and another does not — a fresh
  // install that has verified its number but not yet finished the DOP login, or
  // an older build. Both rows had the same verified mobile and the single-key
  // scheme could not see it, because `mobile` was not a key at all.
  //
  // Union-find instead. Any SHARED strong signal — agent id, account id, or the
  // OTP-verified mobile — merges two devices, and merges chain: phone A shares a
  // mobile with B, B shares an agent id with C, so all three are one agent.
  //
  // Name is deliberately NOT a merge signal. Two different agents can both be
  // "Anjali", and a transitive merge on that would silently fuse two people's
  // books into one row. It stays only as the last-resort bucket for a device
  // with no strong signal at all, exactly as before.
  const parent = new Map<string, string>();
  const find = (x: string): string => {
    let r = x;
    while (parent.get(r) !== r) r = parent.get(r)!;
    while (parent.get(x) !== r) { const n = parent.get(x)!; parent.set(x, r); x = n; }
    return r;
  };
  const union = (a: string, b: string) => {
    const ra = find(a), rb = find(b);
    if (ra !== rb) parent.set(ra, rb);
  };
  for (const d of perDevice) parent.set(d.id, d.id);

  // Mobile is normalised to the last 10 digits: the same number reaches us as
  // 9153471582 and +919153471582 depending on where it was captured, and those
  // must not read as two people.
  const mob10 = (m: string | null) => {
    const digits = (m || "").replace(/\D/g, "");
    return digits.length >= 10 ? digits.slice(-10) : "";
  };

  const firstWithKey = new Map<string, string>();
  for (const d of perDevice) {
    const strong = [
      d.agentId ? `id:${d.agentId}` : "",
      d.account_id ? `acc:${d.account_id}` : "",
      mob10(d.mobile) ? `mob:${mob10(d.mobile)}` : "",
    ].filter(Boolean);
    const keys = strong.length
      ? strong
      : d.name
        ? [`nm:${d.name.toLowerCase()}`]
        : [];
    for (const k of keys) {
      const seen = firstWithKey.get(k);
      if (seen) union(seen, d.id);
      else firstWithKey.set(k, d.id);
    }
  }

  const groups = new Map<string, (typeof perDevice)[number][]>();
  for (const d of perDevice) {
    const k = find(d.id);
    (groups.get(k) || groups.set(k, []).get(k)!).push(d);
  }

  const pick = <T,>(ds: any[], f: (d: any) => T): T | null => { for (const d of ds) { const v = f(d); if (v != null && v !== "") return v; } return null; };
  const rows: UserRow[] = [...groups.values()].map((ds) => {
    const byRecent = [...ds].sort((a, b) => (a.last_seen || "") < (b.last_seen || "") ? 1 : -1);
    const agentId = pick(byRecent, (d) => d.agentId);
    const sub = agentId
      ? subByAgent.get(agentId) ?? (paymentsEnabled ? undefined : ephemeralTrial)
      : undefined;
    const accVals = ds.map((d) => d.accounts).filter((v): v is number => v != null);
    const valVals = ds.map((d) => d.value).filter((v): v is number => v != null);
    const lastSeen = pick(byRecent, (d) => d.last_seen);
    const verified = ds.some((d) => d.phone_verified);
    const accounts = accVals.length ? Math.max(...accVals) : null;
    const name = pick(byRecent, (d) => d.name);
    return {
      device_id: byRecent[0].id,
      device_ids: ds.map((d) => d.id),
      phones: byRecent.map((d) => ({
        id: d.id,
        model: d.model,
        app_version: d.app_version,
        last_seen: d.last_seen,
        signed_in: d.session_live,
      })),
      devices: ds.length,
      // `devices` counts ghosts for ever, so it is not "how many phones is he
      // on". A reinstall and a "Clear data" no longer make one — the id is
      // derived from ANDROID_ID and survives both (DeviceIdentity.id). What
      // still does: an install from before that change (random id each time), a
      // factory reset, a replaced handset, and a build signed with a DIFFERENT
      // key, since ANDROID_ID is scoped per signing key — so the upload-keystore
      // cutover hands every existing agent one new ghost.
      //
      // What the limit actually governs is how many are signed in NOW.
      signed_in: ds.filter((d) => d.session_live).length,
      name,
      mobile: pick(byRecent, (d) => d.mobile),
      model: pick(byRecent, (d) => d.model),
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
      onboarded: !!agentId || verified || accounts != null || !!name,
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
    // PAYING subscribers only — see lib/subs.ts for why this is decided on the
    // plan's PRICE and not on `status` or the string 'trial'. Excluding the
    // derived trial stays important too: it is a read-time value with no row, so
    // counting it would make this tile just restate `agents` while payments are
    // off.
    subscribers: rows.filter((r) => {
      if (!r.agent_id) return false;
      const sub = subByAgent.get(r.agent_id);
      if (!sub?.status) return false; // no real row — derived trial at most
      return isPaying({ plan_code: sub.code, status: sub.status }, paidCodes);
    }).length,
    ai_queries: (aiRes as any).count ?? 0,
  };

  return { rows, totals, region_labels: (cfgRes.data?.value as Record<string, string>) || {} };
}
