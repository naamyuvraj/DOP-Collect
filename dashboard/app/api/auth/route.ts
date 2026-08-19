import { NextRequest, NextResponse } from "next/server";
import {
  COOKIE,
  PENDING_COOKIE,
  mintToken,
  mintPending,
  verifyPending,
  adminId,
  adminIdSource,
  adminIdMatches,
  SESSION_SECONDS,
} from "@/lib/auth";
import {
  adminOtpConfigured,
  otpMessage,
  phoneHint,
  phoneMatches,
  sendAdminCode,
  verifyAdminCode,
} from "@/lib/adminOtp";
import { admin, dbConfigured } from "@/lib/supabase";

/**
 * Login, in two steps when the second factor is configured.
 *
 *   POST { adminId, phone }  -> { step: "otp" }  and a WhatsApp code is sent
 *   POST { otp }             -> the session cookie
 *   POST { resend: true }    -> another code
 *   DELETE                   -> log out
 *
 * The password step sets only a short-lived PENDING cookie, signed over a
 * different message than a session token, so it cannot be used as one. The
 * session cookie is issued at the OTP step and nowhere else — which is the whole
 * point: the shared password on its own no longer reaches any agent's identity,
 * the Groq keys or the delete button.
 *
 * When ADMIN_PHONE / ADMIN_OTP_SECRET are unset the login stays password-only,
 * so shipping this does not lock anyone out before they are configured.
 */
export async function POST(req: NextRequest) {
  const expected = adminId();
  const token = mintToken();
  // Fail closed if the dashboard isn't properly configured — never fall back to
  // the "dopadmin" / "dev-secret" defaults.
  if (!expected || !token) {
    return NextResponse.json(
      { ok: false, error: "not_configured" },
      { status: 500 }
    );
  }

  // Throttle login attempts per IP (10 / 10 min) so the Admin ID can't be
  // brute-forced. Best-effort — never block a legit login on an RPC
  // hiccup.
  const ip = (req.headers.get("x-forwarded-for") || "noip").split(",")[0].trim();
  if (dbConfigured()) {
    try {
      const { data } = await admin().rpc("bump_rate", {
        p_device: `dashlogin:${ip}`,
        p_window_secs: 600,
      });
      if (((data as number) ?? 0) > 10) {
        return NextResponse.json(
          { ok: false, error: "rate_limited" },
          { status: 429 }
        );
      }
    } catch {
      /* ignore throttle errors */
    }
  }

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const otp = String(body.otp ?? "").replace(/\D/g, "");
  const resend = body.resend === true;

  // --- Step 2: the WhatsApp code ------------------------------------------
  // Authorised by the PENDING cookie, not by the password again. Anything
  // reaching here has already passed step 1 within the last 10 minutes.
  if (otp || resend) {
    if (!verifyPending(req.cookies.get(PENDING_COOKIE)?.value)) {
      return NextResponse.json({ ok: false, error: "Start again." }, { status: 401 });
    }
    if (resend) {
      const again = await sendAdminCode();
      return again?.ok
        ? NextResponse.json({ ok: true, step: "otp", hint: phoneHint(), cooldown: again.cooldown ?? 30 })
        : NextResponse.json({ ok: false, error: otpMessage(again?.code) }, { status: sendStatus(again?.code) });
    }
    const v = await verifyAdminCode(otp);
    if (!v?.ok) {
      return NextResponse.json({ ok: false, error: otpMessage(v?.code) }, { status: 401 });
    }
    return grantSession(token);
  }

  // --- Step 1: Admin ID + phone -------------------------------------------
  // The ID is checked FIRST and on its own. Checking the phone before it, or
  // reporting both together, would tell someone who failed the ID whether they
  // at least had the right number.
  if (!adminIdMatches(String(body.adminId ?? ""))) {
    // Which VARIABLE is in play, never its value. Vercel binds env vars at
    // deploy time, so an ADMIN_ID added after the last build is invisible to the
    // running one and the fallback is silently still in use — which looks
    // exactly like typing the wrong thing. This line is the difference between
    // "wrong Admin ID" and knowing why.
    console.warn(`admin login refused — comparing against ${adminIdSource()}`);
    return NextResponse.json({ ok: false }, { status: 401 });
  }

  // Second factor not set up yet — the ID alone signs in, exactly as the
  // password used to. Shipping this must not lock the operator out in the window
  // before ADMIN_PHONE / ADMIN_OTP_SECRET exist.
  if (!adminOtpConfigured()) return grantSession(token);

  // The typed number must BE the pinned one. It confirms which handset you
  // expect the code on; it does not choose where it goes.
  if (!phoneMatches(String(body.phone ?? ""))) {
    return NextResponse.json(
      { ok: false, error: "That is not the registered admin number." },
      { status: 403 },
    );
  }

  const sent = await sendAdminCode();
  if (!sent?.ok) {
    // The password was right, so say what actually went wrong — this is the
    // operator locked out of their own dashboard, and "try again" would leave
    // them guessing at a missing env var.
    return NextResponse.json(
      { ok: false, error: otpMessage(sent?.code) },
      { status: sendStatus(sent?.code) },
    );
  }

  const pending = mintPending();
  if (!pending) {
    return NextResponse.json({ ok: false, error: "not_configured" }, { status: 500 });
  }
  const res = NextResponse.json({
    ok: true,
    step: "otp",
    hint: phoneHint(),
    cooldown: sent.cooldown ?? 30,
  });
  res.cookies.set(PENDING_COOKIE, pending, { ...COOKIE_BASE, maxAge: 600 });
  return res;
}

/** 429 for "too soon / too many", 502 for anything the provider or config broke. */
const sendStatus = (code: string | undefined) =>
  code === "cooldown" || code === "rate_limited" ? 429 : 502;

const COOKIE_BASE = {
  httpOnly: true as const,
  sameSite: "lax" as const,
  secure: process.env.NODE_ENV === "production",
  path: "/",
};

/** Issue the real session and clear any half-finished login. */
function grantSession(token: string) {
  const res = NextResponse.json({ ok: true });
  // Same lifetime the token itself was signed with — see SESSION_DAYS.
  res.cookies.set(COOKIE, token, { ...COOKIE_BASE, maxAge: SESSION_SECONDS });
  res.cookies.set(PENDING_COOKIE, "", { path: "/", maxAge: 0 });
  return res;
}

export async function DELETE() {
  const res = NextResponse.json({ ok: true });
  res.cookies.set(COOKIE, "", { path: "/", maxAge: 0 });
  return res;
}
