// MSG91 OTP volume + spend.
//
// Every WhatsApp OTP the `otp` edge function sends leaves a row in
// otp_requests, so we can count billable messages exactly. What we CANNOT
// count is what they cost: MSG91 bills on its own side and the send API tells
// us nothing about price. So spend on this page is always `sent × the rate you
// typed into app_config.otp_cost` — a burn-rate estimate. The wallet balance
// pulled from MSG91 (see msg91Balance) is the only authoritative money figure.
//
// Reads prefer the v_otp_* views but fall back to aggregating raw otp_requests
// in JS, so the page works before admin/schema_otp_cost.sql has been run.
import { admin, dbConfigured } from "./supabase";

export type OtpDay = {
  day: string;
  sent: number;          // billable — MSG91 accepted a WhatsApp template message
  failed: number;        // we called MSG91 and it errored
  blocked: number;       // our rate limits refused it before calling MSG91
  verified: number;
  verify_failed: number;
  phones: number;
};
export type OtpFailure = { action: string; status: string; n: number; last_seen: string };
export type OtpPhone = {
  phone_hash: string;
  sent: number;
  verified: number;
  blocked: number;
  last_seen: string;
};
export type OtpCost = { currency: string; perMessage: number; monthlyBudget: number };
export type OtpWindow = { sent: number; failed: number; blocked: number; verified: number };

export const DEFAULT_COST: OtpCost = { currency: "INR", perMessage: 0.85, monthlyBudget: 0 };

// Everyone who uses this runs on IST, so a "day" here is an IST calendar day.
// v_otp_daily buckets the same way (`at time zone 'Asia/Kolkata'`); if these two
// ever drift apart the page silently reports different numbers depending on
// whether the views have been created, which is the worst kind of wrong.
const IST_MS = 5.5 * 3_600_000;
/** IST calendar day (YYYY-MM-DD) for an instant. */
const istDay = (t: string | number | Date) =>
  new Date(new Date(t).getTime() + IST_MS).toISOString().slice(0, 10);
/** IST day `n` days back — 0 is today. */
const istDayAgo = (n: number) => istDay(Date.now() - n * 86_400_000);

/** Rows aggregate to the same shape the views produce, keyed by UTC day. */
function foldRaw(rows: { action: string; status: string; created_at: string; phone_hash?: string }[]): OtpDay[] {
  const byDay = new Map<string, OtpDay & { _phones: Set<string> }>();
  for (const r of rows) {
    const day = istDay(r.created_at);
    let d = byDay.get(day);
    if (!d) {
      d = { day, sent: 0, failed: 0, blocked: 0, verified: 0, verify_failed: 0, phones: 0, _phones: new Set() };
      byDay.set(day, d);
    }
    // admin_send is billable — MSG91 charges the same for an admin login code as
    // for an agent's. Excluded, the spend bar under-reports every admin login.
    const isSend =
      r.action === "send" || r.action === "resend" || r.action === "admin_send";
    if (isSend && r.status === "ok") {
      d.sent++;
      if (r.phone_hash) d._phones.add(r.phone_hash);
    } else if (isSend && r.status === "provider_error") d.failed++;
    else if (isSend) d.blocked++; // cooldown | rate_limited | not_configured
    else if (r.action === "verify" || r.action === "admin_verify")
      r.status === "ok" ? d.verified++ : d.verify_failed++;
  }
  return [...byDay.values()]
    .map(({ _phones, ...d }) => ({ ...d, phones: _phones.size }))
    .sort((a, b) => a.day.localeCompare(b.day));
}

/** Daily volume, newest day last (chart order). Empty if the DB isn't set up. */
export async function getOtpDaily(): Promise<OtpDay[]> {
  if (!dbConfigured()) return [];
  const sb = admin();
  const v = await sb.from("v_otp_daily").select("*").order("day");
  if (!v.error && v.data) return v.data as OtpDay[];
  // Pre-SQL fallback. 20k rows covers years at this volume; if it ever caps
  // out, the view exists by then and this branch is dead anyway.
  const { data } = await sb
    .from("otp_requests")
    .select("action,status,created_at,phone_hash")
    .order("created_at", { ascending: false })
    .limit(20_000);
  return foldRaw((data as any[]) || []);
}

/**
 * Totals over the last `days` IST calendar days, today included (0 = all time).
 * days=1 is today alone — hence the days-1, without which every window reaches
 * one day further back than its label claims.
 */
export function windowOf(daily: OtpDay[], days: number): OtpWindow {
  const from = days ? istDayAgo(days - 1) : "";
  const acc = { sent: 0, failed: 0, blocked: 0, verified: 0 };
  for (const d of daily) {
    if (d.day < from) continue;
    acc.sent += Number(d.sent) || 0;
    acc.failed += Number(d.failed) || 0;
    acc.blocked += Number(d.blocked) || 0;
    acc.verified += Number(d.verified) || 0;
  }
  return acc;
}

/** Billable sends since the 1st of the current IST month — the budget bar's input. */
export function monthToDate(daily: OtpDay[]): number {
  const first = istDay(Date.now()).slice(0, 8) + "01";
  return daily.reduce((n, d) => (d.day >= first ? n + (Number(d.sent) || 0) : n), 0);
}

export async function getOtpFailures(): Promise<OtpFailure[]> {
  if (!dbConfigured()) return [];
  const sb = admin();
  const v = await sb.from("v_otp_failures").select("*");
  if (!v.error && v.data) {
    return (v.data as OtpFailure[]).sort((a, b) => b.n - a.n);
  }
  const { data } = await sb
    .from("otp_requests")
    .select("action,status,created_at")
    .neq("status", "ok")
    .order("created_at", { ascending: false })
    .limit(20_000);
  const m = new Map<string, OtpFailure>();
  for (const r of (data as any[]) || []) {
    const k = `${r.action}|${r.status}`;
    const e = m.get(k);
    if (e) { e.n++; if (r.created_at > e.last_seen) e.last_seen = r.created_at; }
    else m.set(k, { action: r.action, status: r.status, n: 1, last_seen: r.created_at });
  }
  return [...m.values()].sort((a, b) => b.n - a.n);
}

/**
 * Phones that consumed the most billable sends. Sent-but-never-verified is the
 * signal worth acting on: someone pulling paid messages who never signs in.
 */
export async function getTopPhones(limit = 12): Promise<OtpPhone[]> {
  if (!dbConfigured()) return [];
  const sb = admin();
  const v = await sb.from("v_otp_top_phones").select("*").order("sent", { ascending: false }).limit(limit);
  if (!v.error && v.data) return v.data as OtpPhone[];
  const { data } = await sb
    .from("otp_requests")
    .select("phone_hash,action,status,created_at")
    .order("created_at", { ascending: false })
    .limit(20_000);
  const m = new Map<string, OtpPhone>();
  for (const r of (data as any[]) || []) {
    let e = m.get(r.phone_hash);
    if (!e) { e = { phone_hash: r.phone_hash, sent: 0, verified: 0, blocked: 0, last_seen: r.created_at }; m.set(r.phone_hash, e); }
    const isSend =
      r.action === "send" || r.action === "resend" || r.action === "admin_send";
    if (isSend && r.status === "ok") e.sent++;
    else if (isSend && r.status !== "provider_error") e.blocked++;
    else if ((r.action === "verify" || r.action === "admin_verify") && r.status === "ok")
      e.verified++;
    if (r.created_at > e.last_seen) e.last_seen = r.created_at;
  }
  return [...m.values()].sort((a, b) => b.sent - a.sent).slice(0, limit);
}

/** Accounts that completed verification — the denominator for cost-per-signup. */
export async function getVerifiedAccounts(): Promise<number> {
  if (!dbConfigured()) return 0;
  const { count } = await admin()
    .from("accounts")
    .select("id", { count: "exact", head: true });
  return count || 0;
}

/**
 * MSG91's own wallet, straight from their control API. Optional: it needs
 * MSG91_AUTHKEY in the dashboard's env (the same key the edge function holds as
 * a Supabase secret). Without it — or if MSG91 is slow or changes the endpoint
 * — the page just hides the panel rather than failing, because every other
 * number here comes from our own database and stands on its own.
 */
export async function msg91Balance(): Promise<Record<string, string> | null> {
  const authkey = process.env.MSG91_AUTHKEY;
  if (!authkey) return null;
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 6000);
    const r = await fetch(
      `https://control.msg91.com/api/balance.php?authkey=${encodeURIComponent(authkey)}&type=4`,
      { signal: ctl.signal, cache: "no-store" }
    );
    clearTimeout(t);
    if (!r.ok) return null;
    const text = (await r.text()).trim();
    // Documented shape is {"SMS":"0.19","VOICE":"0.00","MSG91":"0.19"}, but the
    // endpoint is old enough that a bare number is possible. Accept both.
    try {
      const j = JSON.parse(text);
      if (j && typeof j === "object") {
        const out: Record<string, string> = {};
        for (const [k, v] of Object.entries(j)) out[k] = String(v);
        return out;
      }
    } catch { /* not JSON — fall through */ }
    return Number.isFinite(Number(text)) ? { Balance: text } : null;
  } catch {
    return null;
  }
}
