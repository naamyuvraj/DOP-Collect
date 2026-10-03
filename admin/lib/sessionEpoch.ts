/**
 * "Sign out everywhere" for the admin dashboard.
 *
 * A session cookie was a signed `nonce.exp` and nothing else. The nonce was
 * random but never written down anywhere, so there was no list of live sessions
 * and therefore nothing to revoke: a cookie copied off a laptop stayed valid for
 * its full seven days, and the only way to stop it was to rotate AUTH_SECRET —
 * a redeploy, done under pressure, that also signs the operator out of the
 * machine they are trying to fix things from.
 *
 * The epoch is the cheap version of a session table. It is one integer in
 * `app_config`; every token carries the epoch it was minted under, and a token
 * minted under an older epoch is refused. Raising it invalidates every
 * outstanding cookie at once and costs one row update.
 *
 * What it deliberately does NOT do is revoke ONE session. There is a single
 * admin, so "sign every session out" is the control that was actually missing;
 * per-session revocation would need a row per login and a lookup per request.
 *
 * Edge runtime: plain `fetch` only, no `@supabase/supabase-js`.
 */

export const EPOCH_KEY = "admin_session_epoch";

/** Cached so the gate does not cost a round-trip on every page view. */
let cached: { value: number; at: number } | null = null;

/**
 * How long a raised epoch may take to bite, in ms.
 *
 * Not a security hole so much as a stated bound: revocation is not instant, it
 * is within a minute. Making it instant means a database read on every request
 * to the dashboard, which is a real cost paid always to shorten a window that
 * is rarely used.
 */
export const EPOCH_TTL_MS = 60_000;

function rest(path: string): { url: string; key: string } | null {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return { url: `${url}/rest/v1/${path}`, key };
}

/**
 * The current epoch, or 0 when it has never been set / cannot be read.
 *
 * **Fails to ZERO**, deliberately, and that is a real trade. If Supabase is
 * unreachable, every token verifies against epoch 0 and so every unexpired
 * cookie keeps working — the dashboard stays usable during an outage, and a
 * revocation issued earlier stops being enforced until it comes back. The
 * alternative (fail closed) locks the operator out of their own dashboard
 * whenever the database hiccups, which is the more likely event by far. The
 * password and the WhatsApp code are both still in front of a NEW login.
 */
export async function sessionEpoch(now = Date.now()): Promise<number> {
  if (cached && now - cached.at < EPOCH_TTL_MS) return cached.value;
  const r = rest(`app_config?key=eq.${EPOCH_KEY}&select=value`);
  if (!r) return 0;
  try {
    const res = await fetch(r.url, {
      headers: { apikey: r.key, Authorization: `Bearer ${r.key}` },
      cache: "no-store",
      signal: AbortSignal.timeout(2500),
    });
    if (!res.ok) return cached?.value ?? 0;
    const rows = (await res.json()) as Array<{ value: unknown }>;
    const value = Number(rows?.[0]?.value ?? 0);
    const epoch = Number.isFinite(value) ? value : 0;
    cached = { value: epoch, at: now };
    return epoch;
  } catch {
    return cached?.value ?? 0;
  }
}

/**
 * Raise the epoch, invalidating every session that exists right now —
 * including the caller's own. Returns the new value, or null if it could not
 * be written (in which case nothing was revoked and the caller must say so,
 * never report success).
 */
export async function bumpSessionEpoch(now = Date.now()): Promise<number | null> {
  const r = rest("app_config");
  if (!r) return null;
  // Wall-clock seconds, not `current + 1`: monotonic without needing to trust
  // the value already in the row, so a corrupted or hand-edited epoch cannot
  // make a revocation a no-op.
  const next = Math.floor(now / 1000);
  try {
    const res = await fetch(r.url, {
      method: "POST",
      headers: {
        apikey: r.key,
        Authorization: `Bearer ${r.key}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates",
      },
      body: JSON.stringify({
        key: EPOCH_KEY,
        value: next,
        updated_at: new Date(now).toISOString(),
      }),
      cache: "no-store",
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return null;
    cached = { value: next, at: now };
    return next;
  } catch {
    return null;
  }
}

/** Drop the cache — for tests, and after a bump from another process. */
export function clearEpochCache() {
  cached = null;
}
