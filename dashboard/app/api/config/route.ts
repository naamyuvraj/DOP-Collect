import { NextRequest, NextResponse } from "next/server";
import { admin } from "@/lib/supabase";

export async function GET() {
  const { data } = await admin().from("app_config").select("*");
  const map: Record<string, unknown> = {};
  for (const row of data || []) map[(row as any).key] = (row as any).value;
  return NextResponse.json(map);
}

export async function PUT(req: NextRequest) {
  const { key, value } = await req.json();
  if (!key) return NextResponse.json({ ok: false }, { status: 400 });
  const { error } = await admin()
    .from("app_config")
    .upsert({ key, value, updated_at: new Date().toISOString() });
  return NextResponse.json({ ok: !error, error: error?.message });
}
