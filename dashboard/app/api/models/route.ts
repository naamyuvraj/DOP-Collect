import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";
import { DEFAULT_MODELS, MODELS_CONFIG_KEY, clearModelCache } from "@/lib/groq";

export const dynamic = "force-dynamic";

// Which Groq models the assistant may use, and in what order.
// ---------------------------------------------------------------------------
// This exists because llama-3.3-70b-versatile was decommissioned and started
// returning a hard 404, which took the assistant down until the id was changed
// in four separate files. The list is data now: edit it here, and both the
// dashboard agent and the `groq` edge function pick it up with no deploy.
//
// `available` is fetched live from Groq with a server-side key, so the dropdown
// shows what actually exists today rather than a list that rots in source.

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

async function groqKey(): Promise<string | null> {
  if (dbConfigured()) {
    const { data } = await admin()
      .from("app_keys").select("key").eq("provider", "groq").eq("enabled", true).order("id").limit(1);
    if (data?.[0]?.key) return data[0].key;
  }
  const csv = (process.env.GROQ_KEYS || "").split(",").map((s) => s.trim()).filter(Boolean);
  return csv[0] || process.env.GROQ_KEY_1 || null;
}

/** Chat-capable only — transcription and prompt-guard models can't answer. */
const CHAT_UNSUITABLE = /whisper|prompt-guard|orpheus|tts|guard/i;

export async function GET() {
  const bad = guard();
  if (bad) return bad;
  try {
    let selected: string[] = DEFAULT_MODELS;
    if (dbConfigured()) {
      const { data } = await admin()
        .from("app_config").select("value").eq("key", MODELS_CONFIG_KEY).maybeSingle();
      const v: any = data?.value;
      const list = Array.isArray(v) ? v : Array.isArray(v?.models) ? v.models : null;
      const clean = (list || []).map((m: unknown) => String(m).trim()).filter(Boolean);
      if (clean.length) selected = clean;
    }

    let available: { id: string; context_window?: number; owned_by?: string }[] = [];
    let listError: string | null = null;
    const key = await groqKey();
    if (!key) listError = "no active Groq key — add one below to list live models";
    else {
      try {
        const r = await fetch("https://api.groq.com/openai/v1/models", {
          headers: { Authorization: `Bearer ${key}` },
          cache: "no-store",
        });
        if (!r.ok) listError = `Groq /models -> ${r.status}`;
        else {
          const j = await r.json();
          available = (j?.data || [])
            .filter((m: any) => m?.id && !CHAT_UNSUITABLE.test(m.id))
            .map((m: any) => ({ id: m.id, context_window: m.context_window, owned_by: m.owned_by }))
            .sort((a: any, b: any) => String(a.id).localeCompare(String(b.id)));
        }
      } catch (e) {
        listError = String(e);
      }
    }

    // A configured id Groq no longer serves is the exact failure this page is
    // for, so name it here rather than waiting for a 404 mid-conversation.
    const retired = available.length ? selected.filter((m) => !available.some((a) => a.id === m)) : [];
    return NextResponse.json({ selected, available, defaults: DEFAULT_MODELS, retired, listError });
  } catch (e) {
    return NextResponse.json({ selected: DEFAULT_MODELS, available: [], defaults: DEFAULT_MODELS, retired: [], error: String(e) });
  }
}

export async function PUT(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  try {
    const body = await req.json().catch(() => ({}));
    const models = Array.isArray(body?.models)
      ? body.models.map((m: unknown) => String(m).trim()).filter(Boolean)
      : null;
    if (!models) return NextResponse.json({ ok: false, error: "models must be an array" }, { status: 400 });
    if (!models.length)
      return NextResponse.json({ ok: false, error: "keep at least one model — an empty list disables the assistant" }, { status: 400 });
    // De-dupe but keep order: the order IS the fallback chain.
    const ordered = [...new Set<string>(models)];
    const { error } = await admin()
      .from("app_config")
      .upsert({ key: MODELS_CONFIG_KEY, value: ordered }, { onConflict: "key" });
    if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 500 });
    clearModelCache();
    return NextResponse.json({ ok: true, models: ordered });
  } catch (e) {
    return NextResponse.json({ ok: false, error: String(e) }, { status: 500 });
  }
}
