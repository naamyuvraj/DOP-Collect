/**
 * Request guards for the admin surface, used from `middleware.ts`.
 *
 * These live in the middleware and not in each route on purpose. There are 17
 * API routes with 30-odd handlers between them, and a check you have to remember
 * to add to the next one is a check that will eventually be missing from it. One
 * gate that every request passes through cannot be forgotten.
 *
 * Edge runtime: no Node `crypto`, no `@supabase/supabase-js`. Plain `fetch` and
 * Web Crypto only.
 */

/** Caller's IP, as far as the proxy will tell us. */
export function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0].trim();
  return req.headers.get("x-real-ip")?.trim() || "noip";
}

const MUTATING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
export const isMutating = (method: string) => MUTATING.has(method.toUpperCase());

/**
 * Does this write come from the dashboard itself?
 *
 * The session cookie is SameSite=Lax, so a browser already declines to attach it
 * to a cross-site POST — but Lax is a browser-side promise, it does nothing for
 * a same-site subdomain, and it is not the kind of thing to rest a DELETE on.
 * This is the server saying no as well.
 *
 * Checks Origin first and falls back to Referer, because a few clients omit
 * Origin on same-origin requests. A write with NEITHER header is refused: every
 * browser sends one on a fetch/XHR, so their joint absence means the caller is
 * not the dashboard. That also means `curl` cannot write without passing an
 * explicit Origin, which is the intended trade — the admin API is for the admin
 * UI, and a script that needs it can say where it is from.
 */
export function sameOrigin(req: Request): boolean {
  const host = req.headers.get("host");
  if (!host) return false;

  const claimed = req.headers.get("origin") || req.headers.get("referer");
  if (!claimed) return false;

  try {
    return new URL(claimed).host === host;
  } catch {
    return false; // unparseable Origin/Referer is not a pass
  }
}

/**
 * Per-IP counter, on the same `bump_rate` RPC the login throttle and the edge
 * functions already use — one definition of "too many", shared.
 *
 * Returns true when the request is allowed. **Fails OPEN**: if Supabase is
 * unreachable or the RPC errors, the request proceeds. A rate limiter that locks
 * the operator out of their own dashboard during an incident is worse than no
 * rate limiter, and the auth gate is still in front of everything either way.
 */
export async function withinRate(
  bucket: string,
  windowSecs: number,
  max: number,
): Promise<boolean> {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return true; // not configured — nothing to count with

  try {
    const res = await fetch(`${url}/rest/v1/rpc/bump_rate`, {
      method: "POST",
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_device: bucket, p_window_secs: windowSecs }),
      cache: "no-store",
      signal: AbortSignal.timeout(2500),
    });
    if (!res.ok) return true;
    const n = Number(await res.json());
    return !Number.isFinite(n) || n <= max;
  } catch {
    return true;
  }
}

/**
 * Limits, per IP. Writes are rare in real use — a handful across a whole
 * session — so 40/min is generous for a person and stingy for a loop. Reads are
 * higher because a single page can fan out to several endpoints and the charts
 * refetch.
 */
export const LIMITS = {
  write: { window: 60, max: 40 },
  read: { window: 60, max: 600 },
};

/**
 * Headers applied to every response.
 *
 * No `script-src` CSP: Next injects inline bootstrap script, so a strict policy
 * needs per-request nonces threaded through the app, and getting that subtly
 * wrong takes the dashboard down. `frame-ancestors` is the part that actually
 * matters here (clickjacking an admin panel), and it needs no nonces.
 */
export function securityHeaders(isHttps: boolean): Record<string, string> {
  return {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "frame-ancestors 'none'",
    // The admin URLs name agents and accounts; don't leak them to anything the
    // operator clicks through to.
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    "Cross-Origin-Opener-Policy": "same-origin",
    // Behind a password, but the login page is public and need not be indexed.
    "X-Robots-Tag": "noindex, nofollow",
    ...(isHttps
      ? { "Strict-Transport-Security": "max-age=31536000; includeSubDomains" }
      : {}),
  };
}
