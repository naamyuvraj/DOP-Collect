import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// The pin board.
// ---------------------------------------------------------------------------
// Stored as one JSON array in `app_config.board_notes` rather than a table, so
// it works the moment this deploys — no schema_*.sql for anyone to remember to
// run, which is exactly how the devices.name / v_devices breakages started.
//
// The tradeoff is that a save writes the whole board, so two people editing at
// once would have a last-write-wins collision. For a single-admin panel that is
// the right trade; if the board ever gets shared, move it to its own table with
// a row per note.

const KEY = "board_notes";
const MAX_NOTES = 200;
const MAX_TEXT = 2000;

export type Note = {
  id: string;
  text: string;
  color: "yellow" | "white" | "ink";
  x: number;
  y: number;
  done?: boolean;
  pinned?: boolean;
  updated_at?: string;
};

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

const COLORS = new Set(["yellow", "white", "ink"]);

/** Never trust the client with the shape — a bad note would break every load. */
function clean(raw: unknown): Note[] {
  if (!Array.isArray(raw)) return [];
  return raw.slice(0, MAX_NOTES).map((n: any, i: number) => ({
    id: String(n?.id ?? `n${i}`).slice(0, 40),
    text: String(n?.text ?? "").slice(0, MAX_TEXT),
    color: COLORS.has(n?.color) ? n.color : "yellow",
    x: Math.max(0, Math.min(4000, Number(n?.x) || 0)),
    y: Math.max(0, Math.min(4000, Number(n?.y) || 0)),
    done: !!n?.done,
    pinned: !!n?.pinned,
    updated_at: typeof n?.updated_at === "string" ? n.updated_at : undefined,
  }));
}

export async function GET() {
  const bad = guard();
  if (bad) return bad;
  if (!dbConfigured()) return NextResponse.json({ notes: [] });
  try {
    const { data } = await admin().from("app_config").select("value").eq("key", KEY).maybeSingle();
    return NextResponse.json({ notes: clean(data?.value) });
  } catch (e) {
    return NextResponse.json({ notes: [], error: String(e) });
  }
}

export async function PUT(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const body = await req.json().catch(() => ({}));
    const notes = clean(body?.notes);
    const { error } = await admin()
      .from("app_config")
      .upsert({ key: KEY, value: notes }, { onConflict: "key" });
    if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 500 });
    return NextResponse.json({ ok: true, notes });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 500 });
  }
}
