import { cookies } from "next/headers";
import { createHmac, randomBytes } from "crypto";

export const COOKIE = "dop_admin";

// Insecure defaults that must NEVER be accepted in a real deployment.
const DEFAULT_SECRET = "dev-secret";
const DEFAULT_PASSWORD = "dopadmin";

/** The signing secret, or null if unset / left at the insecure default. */
export function authSecret(): string | null {
  const s = process.env.AUTH_SECRET;
  return !s || s === DEFAULT_SECRET ? null : s;
}

/** The admin password, or null if unset / left at the insecure default. */
export function adminPassword(): string | null {
  const p = process.env.DASHBOARD_PASSWORD;
  return !p || p === DEFAULT_PASSWORD ? null : p;
}

function sign(secret: string, body: string): string {
  return createHmac("sha256", secret).update(body).digest("hex");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

/**
 * A fresh, per-session signed token: `nonce.exp.sig` where
 * sig = HMAC-SHA256(AUTH_SECRET, `nonce.exp`). Unique per login (nonce) and
 * time-bound (exp), so the cookie is NOT the raw secret and rotating
 * AUTH_SECRET invalidates every existing session. Null if misconfigured.
 */
export function mintToken(ttlDays = 30): string | null {
  const secret = authSecret();
  if (!secret) return null;
  const nonce = randomBytes(16).toString("hex");
  const exp = Date.now() + ttlDays * 86400_000;
  const body = `${nonce}.${exp}`;
  return `${body}.${sign(secret, body)}`;
}

/** Verify a token's signature + expiry (constant-time). */
export function verifyToken(token: string | undefined | null): boolean {
  const secret = authSecret();
  if (!secret || !token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  const [nonce, exp, sig] = parts;
  if (!nonce || !exp || !sig || Number(exp) < Date.now()) return false;
  return timingSafeEqual(sign(secret, `${nonce}.${exp}`), sig);
}

export function isAuthed(): boolean {
  return verifyToken(cookies().get(COOKIE)?.value);
}
