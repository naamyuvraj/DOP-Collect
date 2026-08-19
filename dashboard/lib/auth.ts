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

/**
 * The secret typed into the "Admin ID" field.
 *
 * `ADMIN_ID` if it is set, otherwise `DASHBOARD_PASSWORD`. The fallback is what
 * makes the rename safe to deploy: without it, shipping this would lock the
 * operator out of their own dashboard in the window between the deploy and
 * setting the new variable.
 *
 * It is the ONLY knowledge factor now — the password field is gone — so treat it
 * as a password, not a username. A guessable ADMIN_ID leaves the WhatsApp code
 * as the only thing standing in front of every agent's identity.
 */
export function adminId(): string | null {
  const v = process.env.ADMIN_ID;
  if (v && v !== DEFAULT_PASSWORD) return v;
  return adminPassword();
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

export const PENDING_COOKIE = "dop_admin_pending";

/**
 * A token for "the password was right, the WhatsApp code is still owed".
 *
 * Signed over `pending.<nonce>.<exp>` while a session token is signed over
 * `<nonce>.<exp>`. Same shape, different signed message, so the two can never
 * be swapped: a pending token presented as a session cookie fails
 * [verifyToken], and a session token presented at the OTP step fails
 * [verifyPending]. Without that separation, holding one would mean holding the
 * other and the second factor would be decorative.
 *
 * Short-lived on purpose — it is a half-finished login, not a session.
 */
export function mintPending(ttlMinutes = 10): string | null {
  const secret = authSecret();
  if (!secret) return null;
  const nonce = randomBytes(16).toString("hex");
  const exp = Date.now() + ttlMinutes * 60_000;
  const body = `${nonce}.${exp}`;
  return `${body}.${sign(secret, `pending.${body}`)}`;
}

/** Verify a pending token's signature + expiry (constant-time). */
export function verifyPending(token: string | undefined | null): boolean {
  const secret = authSecret();
  if (!secret || !token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  const [nonce, exp, sig] = parts;
  if (!nonce || !exp || !sig || Number(exp) < Date.now()) return false;
  return timingSafeEqual(sign(secret, `pending.${nonce}.${exp}`), sig);
}

/**
 * Constant-time check of the typed Admin ID.
 *
 * `given !== expected` short-circuits on the first differing byte, and on a
 * length mismatch before that — so it leaks both. HMAC both sides first and the
 * compared values are a fixed 64 hex chars whatever went in, which leaves
 * nothing for the comparison to leak. The login throttle makes this hard to
 * exploit over a network; it costs one line not to rely on that.
 */
export function adminIdMatches(given: string): boolean {
  const expected = adminId();
  const secret = authSecret();
  if (!expected || !secret || !given) return false;
  return timingSafeEqual(sign(secret, given), sign(secret, expected));
}

export function isAuthed(): boolean {
  return verifyToken(cookies().get(COOKIE)?.value);
}
