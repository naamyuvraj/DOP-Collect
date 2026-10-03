import { NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// How the AGENTS' in-app chat assistant is behaving.
// ---------------------------------------------------------------------------
// Not to be confused with /assistant, which is the dashboard's OWN assistant
// (ask it about installs and revenue). This is telemetry about the thing the
// agent talks to on his handset.
//
// Everything here already existed and was never surfaced:
//   events.assistant_query   source | kind | lang | ok
//   events.assistant_action  kind | ok
//   key_usage                model | ok        (Groq key rotation)
//
// PRIVACY: the question text is deliberately not logged by the app — see
// AssistantService, "log only how it was answered — never the question text".
// So this can say where answers came from and what they were about, and can
// never say what was asked. That is the right trade and it is not a gap to be
// filled later.

export type ChatPoint = { day: string; total: number; failed: number };
export type ChatSlice = { key: string; n: number; failed: number };
export type ChatData = {
  total: number;
  failed: number;
  answeredLocally: number;
  actions: number;
  bySource: ChatSlice[];
  byKind: ChatSlice[];
  byLang: ChatSlice[];
  byVersion: ChatSlice[];
  byModel: ChatSlice[];
  perDay: ChatPoint[];
  topDevices: { device: string; n: number; failed: number }[];
  notes: string[];
};

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

/** Count by a key, tracking how many of each were failures. */
function tally(
  rows: { k: string | null | undefined; ok: boolean }[],
): ChatSlice[] {
  const m = new Map<string, ChatSlice>();
  for (const r of rows) {
    const key = (r.k ?? "unknown") || "unknown";
    const s = m.get(key) ?? { key, n: 0, failed: 0 };
    s.n++;
    if (!r.ok) s.failed++;
    m.set(key, s);
  }
  return [...m.values()].sort((a, b) => b.n - a.n);
}

export async function GET(req: Request) {
  const bad = guard();
  if (bad) return bad;

  const empty: ChatData = {
    total: 0, failed: 0, answeredLocally: 0, actions: 0,
    bySource: [], byKind: [], byLang: [], byVersion: [], byModel: [],
    perDay: [], topDevices: [], notes: [],
  };
  if (!dbConfigured()) return NextResponse.json(empty);

  const days = Math.min(90, Math.max(1, Number(new URL(req.url).searchParams.get("days") ?? 30)));
  const since = new Date(Date.now() - days * 86400_000).toISOString();
  const sb = admin();
  const notes: string[] = [];

  const { data: evRaw, error: evErr } = await sb
    .from("events")
    .select("event, props, app_version, device_id, created_at")
    .like("event", "assistant%")
    .gte("created_at", since)
    .order("created_at", { ascending: false })
    .limit(5000);
  if (evErr) notes.push(`events unavailable: ${evErr.message}`);

  type Ev = {
    event: string;
    props: Record<string, unknown> | null;
    app_version: string | null;
    device_id: string | null;
    created_at: string;
  };
  const ev = ((evRaw as Ev[]) ?? []);
  const queries = ev.filter((r) => r.event === "assistant_query");
  const actions = ev.filter((r) => r.event === "assistant_action");

  // `ok` is a real field on both events; treat a missing one as a success
  // rather than inventing a failure the app never reported.
  const okOf = (r: Ev) => (r.props?.ok === false ? false : true);
  const strOf = (r: Ev, k: string) => {
    const v = r.props?.[k];
    return typeof v === "string" ? v : v == null ? null : String(v);
  };

  const failed = queries.filter((r) => !okOf(r)).length;

  // Per-day series, oldest first so a chart reads left to right.
  const dayMap = new Map<string, ChatPoint>();
  for (const r of queries) {
    const day = r.created_at.slice(0, 10);
    const p = dayMap.get(day) ?? { day, total: 0, failed: 0 };
    p.total++;
    if (!okOf(r)) p.failed++;
    dayMap.set(day, p);
  }
  const perDay = [...dayMap.values()].sort((a, b) => a.day.localeCompare(b.day));

  const devMap = new Map<string, { device: string; n: number; failed: number }>();
  for (const r of queries) {
    const device = r.device_id ?? "unknown";
    const d = devMap.get(device) ?? { device, n: 0, failed: 0 };
    d.n++;
    if (!okOf(r)) d.failed++;
    devMap.set(device, d);
  }

  // Groq key rotation. A model failing often here is the likeliest cause of a
  // slow or dead answer on the handset, and it is invisible everywhere else.
  const { data: kuRaw, error: kuErr } = await sb
    .from("key_usage")
    .select("model, ok, created_at")
    .gte("created_at", since)
    .limit(5000);
  if (kuErr) notes.push(`key_usage unavailable: ${kuErr.message}`);
  const ku = ((kuRaw as { model: string | null; ok: boolean | null }[]) ?? []);

  if (!queries.length) {
    notes.push(
      "No assistant_query events in this window. The app only reports them " +
      "from builds that carry assistant telemetry.",
    );
  }
  notes.push("Question text is never logged, by design — only how it was answered.");

  const out: ChatData = {
    total: queries.length,
    failed,
    answeredLocally: queries.filter((r) => (strOf(r, "source") ?? "").startsWith("local")).length,
    actions: actions.length,
    bySource: tally(queries.map((r) => ({ k: strOf(r, "source"), ok: okOf(r) }))),
    byKind: tally(queries.map((r) => ({ k: strOf(r, "kind"), ok: okOf(r) }))),
    byLang: tally(queries.map((r) => ({ k: strOf(r, "lang"), ok: okOf(r) }))),
    byVersion: tally(queries.map((r) => ({ k: r.app_version, ok: okOf(r) }))),
    byModel: tally(ku.map((r) => ({ k: r.model, ok: r.ok !== false }))),
    perDay,
    topDevices: [...devMap.values()].sort((a, b) => b.n - a.n).slice(0, 10),
    notes,
  };
  return NextResponse.json(out);
}
