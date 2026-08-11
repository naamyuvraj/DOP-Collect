import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// Robustness: guard auth in-handler (defence in depth beside middleware) and
// wrap in try/catch so a Supabase outage returns JSON, never an HTML 500 that
// the client would misread as a "network error".
const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

export async function GET() {
  const bad = guard();
  if (bad) return bad;
  if (!dbConfigured()) return NextResponse.json({});
  try {
    const { data, error } = await admin().from("app_config").select("*");
    if (error) return NextResponse.json({ error: error.message }, { status: 200 });
    const map: Record<string, unknown> = {};
    for (const row of data || []) map[(row as any).key] = (row as any).value;
    return NextResponse.json(map);
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 200 });
  }
}

export async function PUT(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const { key, value } = await req.json().catch(() => ({}));
    if (!key) return NextResponse.json({ ok: false, error: "key is required" }, { status: 400 });
    const { error } = await admin()
      .from("app_config")
      .upsert({ key, value, updated_at: new Date().toISOString() });
    return NextResponse.json({ ok: !error, error: error?.message });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 200 });
  }
}
