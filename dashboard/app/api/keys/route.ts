import { NextRequest, NextResponse } from "next/server";
import { admin } from "@/lib/supabase";

const mask = (k: string) =>
  !k || k.length <= 10 ? "••••" : `${k.slice(0, 6)}…${k.slice(-4)}`;

export async function GET() {
  const sb = admin();
  const [{ data: keys }, { data: usage }] = await Promise.all([
    sb.from("app_keys").select("*").order("id"),
    sb.from("v_key_usage").select("*"),
  ]);
  return NextResponse.json({
    keys: (keys || []).map((k: any) => ({ ...k, key: mask(k.key) })),
    usage: usage || [],
  });
}

export async function POST(req: NextRequest) {
  const { provider, label, key } = await req.json();
  if (!key) return NextResponse.json({ ok: false }, { status: 400 });
  const { error } = await admin()
    .from("app_keys")
    .insert({ provider: provider || "groq", label, key });
  return NextResponse.json({ ok: !error, error: error?.message });
}

export async function PATCH(req: NextRequest) {
  const { id, enabled } = await req.json();
  const { error } = await admin()
    .from("app_keys")
    .update({ enabled })
    .eq("id", id);
  return NextResponse.json({ ok: !error, error: error?.message });
}

export async function DELETE(req: NextRequest) {
  const { id } = await req.json();
  const { error } = await admin().from("app_keys").delete().eq("id", id);
  return NextResponse.json({ ok: !error, error: error?.message });
}
