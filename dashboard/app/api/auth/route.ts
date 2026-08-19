import { NextRequest, NextResponse } from "next/server";
import { COOKIE, mintToken, adminPassword, passwordMatches } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

// POST { password } -> set the session cookie. DELETE -> log out.
export async function POST(req: NextRequest) {
  const expected = adminPassword();
  const token = mintToken();
  // Fail closed if the dashboard isn't properly configured — never fall back to
  // the "dopadmin" / "dev-secret" defaults.
  if (!expected || !token) {
    return NextResponse.json(
      { ok: false, error: "not_configured" },
      { status: 500 }
    );
  }

  // Throttle login attempts per IP (10 / 10 min) so the single shared password
  // can't be brute-forced. Best-effort — never block a legit login on an RPC
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

  const { password } = await req.json().catch(() => ({ password: "" }));
  if (!passwordMatches(String(password ?? ""))) {
    return NextResponse.json({ ok: false }, { status: 401 });
  }

  const res = NextResponse.json({ ok: true });
  res.cookies.set(COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });
  return res;
}

export async function DELETE() {
  const res = NextResponse.json({ ok: true });
  res.cookies.set(COOKIE, "", { path: "/", maxAge: 0 });
  return res;
}
