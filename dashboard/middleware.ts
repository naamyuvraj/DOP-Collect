import { NextRequest, NextResponse } from "next/server";

const COOKIE = "dop_admin";
const DEFAULT_SECRET = "dev-secret";

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

// Gate everything except the login page and the auth endpoint.
export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;
  const isPublic =
    pathname.startsWith("/login") ||
    pathname.startsWith("/privacy") || // public policy page (Play Store link)
    pathname.startsWith("/api/auth") ||
    pathname.startsWith("/_next") ||
    pathname === "/favicon.ico";

  if (isPublic) return NextResponse.next();

  const secret = process.env.AUTH_SECRET;
  const ok =
    !!secret &&
    secret !== DEFAULT_SECRET &&
    (await verify(req.cookies.get(COOKIE)?.value, secret));
  if (ok) return NextResponse.next();

  const url = req.nextUrl.clone();
  url.pathname = "/login";
  url.searchParams.set("next", pathname);
  return NextResponse.redirect(url);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
