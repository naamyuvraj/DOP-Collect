import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";
import {
  DEFAULT_COST, OtpCost, getOtpDaily, getOtpFailures, getTopPhones,
  getVerifiedAccounts, monthToDate, msg91Balance, windowOf,
} from "@/lib/otp";

export const dynamic = "force-dynamic";

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

// Only these app_config keys are writable here. This route exists to tune OTP
// spend, not to be a second, unaudited way to write any config key.
const WRITABLE = new Set(["otp_cost", "otp_limits", "otp_required", "max_devices"]);

export async function GET() {
  const bad = guard();
  if (bad) return bad;
  if (!dbConfigured())
    return NextResponse.json({ daily: [], failures: [], top: [], cost: DEFAULT_COST, config: {} });
  try {
    const sb = admin();
    const [daily, failures, top, verifiedAccounts, balance, cfgRes] = await Promise.all([
      getOtpDaily(),
      getOtpFailures(),
      getTopPhones(),
      getVerifiedAccounts(),
      msg91Balance(),
      sb.from("app_config").select("key,value")
        .in("key", ["otp_cost", "otp_limits", "otp_required", "max_devices"]),
    ]);

    const config: Record<string, any> = {};
    for (const row of (cfgRes.data as any[]) || []) config[row.key] = row.value;
    const cost: OtpCost = { ...DEFAULT_COST, ...(config.otp_cost || {}) };

    return NextResponse.json({
      daily,
      failures,
      top,
      verifiedAccounts,
      balance,
      cost,
      config,
      windows: {
        d1: windowOf(daily, 1),
        d7: windowOf(daily, 7),
        d30: windowOf(daily, 30),
        all: windowOf(daily, 0),
      },
      mtdSent: monthToDate(daily),
    });
  } catch (e) {
    // Always JSON — an HTML 500 here reads to the client as "network error".
    return NextResponse.json(
      { daily: [], failures: [], top: [], cost: DEFAULT_COST, config: {}, error: String(e) },
      { status: 200 }
    );
  }
}

export async function PUT(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const { key, value } = await req.json().catch(() => ({}));
    if (!WRITABLE.has(key))
      return NextResponse.json({ ok: false, error: `key "${key}" is not writable here` }, { status: 400 });
    const { error } = await admin()
      .from("app_config")
      .upsert({ key, value, updated_at: new Date().toISOString() });
    return NextResponse.json({ ok: !error, error: error?.message });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 200 });
  }
}
