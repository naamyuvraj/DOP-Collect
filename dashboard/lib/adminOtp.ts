/**
 * Client for the `otp` edge function's admin actions — the dashboard's WhatsApp
 * second factor.
 *
 * The code itself is generated, stored, hashed, expired and attempt-capped in
 * the edge function, because that is where the MSG91 auth key already lives and
 * where all of that is already written and tested. This file only asks.
 *
 * Server-side only. `ADMIN_OTP_SECRET` must never reach the browser.
 */

const adminPhone = () => (process.env.ADMIN_PHONE || "").replace(/\D/g, "").slice(-10);
// Trimmed on both sides of the wire. A long random string pasted into the
// Vercel UI keeps a trailing newline that is invisible there, and Supabase has
// it without — the header then never matches and the only symptom is
// "forbidden", which reads as a missing secret rather than a whitespace one.
const adminSecret = () => (process.env.ADMIN_OTP_SECRET || "").trim();

/**
 * What the RUNNING deployment can actually see — names and booleans, never
 * values.
 *
 * This exists because "I set the variables and it still logs straight in" has
 * no visible cause otherwise. Vercel binds env vars at deploy time, so a
 * variable added after the last build is invisible to it; one set only for the
 * Preview scope is invisible to Production; and a phone that is not 10 digits
 * leaves adminOtpConfigured() false. All three look identical from the login
 * screen: it just lets you in.
 */
export function adminOtpStatus() {
  const phoneRaw = (process.env.ADMIN_PHONE || "").trim();
  const phone = adminPhone();
  const secret = adminSecret();
  const active = adminOtpConfigured();

  let reason = "";
  if (active) reason = "Active — a code is required to sign in.";
  else if (!phoneRaw && !secret)
    reason = "Neither variable is visible to this deployment. If you have set them, redeploy — Vercel binds env vars at build time.";
  else if (phoneRaw && phone.length !== 10)
    reason = `ADMIN_PHONE is set but has ${phone.length} digits, not 10.`;
  else if (!secret) reason = "ADMIN_OTP_SECRET is not visible to this deployment.";
  else reason = "ADMIN_PHONE is not visible to this deployment.";

  return {
    active,
    adminPhoneSet: phoneRaw.length > 0,
    adminPhoneDigits: phone.length,
    adminOtpSecretSet: secret.length > 0,
    reason,
  };
}

/**
 * Is the second factor switched on?
 *
 * Both halves have to be present. This is deliberately a soft switch: until the
 * env vars exist the login stays password-only, so deploying this code does not
 * lock the operator out of their own dashboard before they have set them up.
 * Set both and the second factor starts applying on the next login.
 */
export function adminOtpConfigured(): boolean {
  return adminPhone().length === 10 && adminSecret().length > 0;
}

/** "•••••• 210" — enough to confirm which handset, not enough to be a leak. */
export function phoneHint(): string {
  const p = adminPhone();
  return p ? `•••••••${p.slice(-3)}` : "";
}

/**
 * Is the typed number the pinned admin number?
 *
 * The phone field is a confirmation, not a choice. Without this check anyone
 * past the Admin ID could send WhatsApp codes to any number — someone else's
 * handset, on your MSG91 bill — and could point the second factor at a phone
 * they control, which would make it no factor at all.
 */
export function phoneMatches(typed: string): boolean {
  const want = adminPhone();
  const got = (typed || "").replace(/\D/g, "").slice(-10);
  return want.length === 10 && got === want;
}

type Reply = { ok: boolean; code?: string; cooldown?: number };

async function call(action: string, extra: Record<string, unknown> = {}): Promise<Reply | null> {
  const url = process.env.SUPABASE_URL;
  const anon = process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anon || !adminOtpConfigured()) return null;
  try {
    const res = await fetch(`${url}/functions/v1/otp`, {
      method: "POST",
      headers: {
        apikey: anon,
        Authorization: `Bearer ${anon}`,
        "Content-Type": "application/json",
        // The gate on the admin actions. Not the anon key — that ships inside
        // the APK and identifies nothing.
        "x-admin-secret": adminSecret(),
      },
      body: JSON.stringify({ action, phone: adminPhone(), ...extra }),
      cache: "no-store",
      signal: AbortSignal.timeout(15000),
    });
    return (await res.json()) as Reply;
  } catch {
    return null; // network / timeout — the caller reports "try again"
  }
}

/** Send a fresh code to the pinned admin number. */
export const sendAdminCode = () => call("admin_send");

/** Check a code. Consumed on success, so it cannot be replayed. */
export const verifyAdminCode = (otp: string) => call("admin_verify", { otp });

/** Server code -> something a person can act on. */
export function otpMessage(code: string | undefined): string {
  switch (code) {
    case "invalid_otp":
      return "Wrong code. Check it and try again.";
    case "expired":
      return "That code expired. Send a new one.";
    case "too_many_attempts":
      return "Too many wrong tries. Send a new code.";
    case "cooldown":
      return "A code was just sent. Wait a moment before asking for another.";
    case "rate_limited":
      return "Too many codes requested. Try again shortly.";
    case "not_admin_phone":
      return "ADMIN_PHONE here and in Supabase do not match.";
    case "forbidden":
      return "ADMIN_OTP_SECRET is missing or does not match Supabase.";
    case "not_configured":
      return "WhatsApp sending is not configured on the otp function.";
    case "provider_down":
      return "WhatsApp would not take the message. Try again shortly.";
    default:
      return "Could not send the code. Try again.";
  }
}
