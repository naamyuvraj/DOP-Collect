import { NextRequest, NextResponse } from "next/server";
import {
  LIMITS,
  clientIp,
  isMutating,
  sameOrigin,
  securityHeaders,
  withinRate,
} from "@/lib/guard";

const COOKIE = "dop_admin";
const DEFAULT_SECRET = "dev-secret";

/** Anything served straight out of public/ — images, icons, fonts, manifests. */
const PUBLIC_FILE =
  /\.(png|jpe?g|gif|svg|webp|avif|ico|bmp|txt|xml|json|webmanifest|woff2?|ttf|otf|map)$/i;

// Verify the signed session token (nonce.exp.sig) using Web Crypto — the Node
// `crypto` module isn't available in the Edge middleware runtime. Kept in sync
// with lib/auth.ts (same HMAC-SHA256 over `nonce.exp`).
async function verify(token: string | undefined, secret: string): Promise<boolean> {
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  const [nonce, exp, sig] = parts;
  if (!nonce || !exp || !sig || Number(exp) < Date.now()) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const s = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${nonce}.${exp}`)
  );
  const expected = [...new Uint8Array(s)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  if (expected.length !== sig.length) return false;
  let r = 0;
  for (let i = 0; i < expected.length; i++) r |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return r === 0;
}

/**
 * The single gate: security headers, CSRF origin check, per-IP rate limit, then
 * the auth cookie.
 *
 * Order matters. The origin check and the rate limit run BEFORE the auth check
 * and apply to `/api/auth` too — that endpoint is the one an attacker actually
 * wants, and exempting it because it is "public" would leave the login itself
 * the only unguarded thing on the dashboard.
 */
export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;
  const headers = securityHeaders(req.nextUrl.protocol === "https:");
  const pass = () => {
    const res = NextResponse.next();
    for (const [k, v] of Object.entries(headers)) res.headers.set(k, v);
    return res;
  };
  const deny = (status: number, error: string) =>
    NextResponse.json({ ok: false, error }, { status, headers });

  // Static assets: headers only, no checks, no database round-trip.
  //
  // PUBLIC_FILE matters more than it looks. Everything under public/ is matched
  // by this middleware, so an unauthenticated request for /logo.png was being
  // 307'd to /login — the browser asked for a PNG, got an HTML page, and drew a
  // broken image. On the login screen, which is the one page guaranteed to be
  // unauthenticated and the first thing anyone sees.
  //
  // Safe to let through: these are files in public/, which are served to the
  // world by definition, and no route ends in one of these extensions.
  if (pathname.startsWith("/_next") || PUBLIC_FILE.test(pathname)) return pass();

  // 1. CSRF. Every state-changing request must say it came from here.
  if (isMutating(req.method) && !sameOrigin(req)) {
    return deny(403, "bad_origin");
  }

  // 2. Rate limit, per IP. Only /api/* — page navigations cost a Supabase
  //    round-trip to count and are not the thing worth counting.
  if (pathname.startsWith("/api/")) {
    const ip = clientIp(req);
    const write = isMutating(req.method);
    const { window, max } = write ? LIMITS.write : LIMITS.read;
    if (!(await withinRate(`dash:${ip}:${write ? "w" : "r"}`, window, max))) {
      return deny(429, "rate_limited");
    }
  }

  // 3. Auth. `/api/auth` is how you GET a cookie, and /login + /privacy are
  //    meant to be reachable without one.
  const isPublic =
    pathname.startsWith("/login") ||
    pathname.startsWith("/privacy") || // public policy page (Play Store link)
    pathname.startsWith("/api/auth");
  if (isPublic) return pass();

  const secret = process.env.AUTH_SECRET;
  const ok =
    !!secret &&
    secret !== DEFAULT_SECRET &&
    (await verify(req.cookies.get(COOKIE)?.value, secret));
  if (ok) return pass();

  // An unauthenticated API call gets a 401, not a redirect to an HTML page —
  // fetch() cannot do anything useful with a 307 to /login.
  if (pathname.startsWith("/api/")) return deny(401, "unauthorized");

  const url = req.nextUrl.clone();
  url.pathname = "/login";
  url.searchParams.set("next", pathname);
  const res = NextResponse.redirect(url);
  for (const [k, v] of Object.entries(headers)) res.headers.set(k, v);
  return res;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
