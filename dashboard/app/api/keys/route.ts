import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// Robustness: auth guard + try/catch on every handler so a Supabase outage or
// missing table returns JSON, never an HTML 500 the client misreads as a
// "network error".
const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

const mask = (k: string) =>
  !k || k.length <= 10 ? "••••" : `${k.slice(0, 6)}…${k.slice(-4)}`;

export async function GET() {
  const bad = guard();
  if (bad) return bad;
  if (!dbConfigured()) return NextResponse.json({ keys: [], usage: [] });
  try {
    const sb = admin();
    const [{ data: keys }, { data: usage }] = await Promise.all([
      sb.from("app_keys").select("*").order("id"),
      sb.from("v_key_usage").select("*"),
    ]);
    return NextResponse.json({
      keys: (keys || []).map((k: any) => ({ ...k, key: mask(k.key) })),
      usage: usage || [],
    });
  } catch (e) {
    return NextResponse.json({ keys: [], usage: [], error: String(e) }, { status: 200 });
  }
}

export async function POST(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const { provider, label, key } = await req.json().catch(() => ({}));
    if (!key) return NextResponse.json({ ok: false, error: "key is required" }, { status: 400 });
    const { error } = await admin()
      .from("app_keys")
      .insert({ provider: provider || "groq", label, key });
    return NextResponse.json({ ok: !error, error: error?.message });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 200 });
  }
}

export async function PATCH(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const { id, enabled } = await req.json().catch(() => ({}));
    if (id == null) return NextResponse.json({ ok: false, error: "id is required" }, { status: 400 });
    const { error } = await admin().from("app_keys").update({ enabled }).eq("id", id);
    return NextResponse.json({ ok: !error, error: error?.message });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 200 });
  }
}

export async function DELETE(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const { id } = await req.json().catch(() => ({}));
    if (id == null) return NextResponse.json({ ok: false, error: "id is required" }, { status: 400 });
    const { error } = await admin().from("app_keys").delete().eq("id", id);
    return NextResponse.json({ ok: !error, error: error?.message });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 200 });
  }
}
