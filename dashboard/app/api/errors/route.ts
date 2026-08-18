import { NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// Everything that failed, from every source that already records failure.
// ---------------------------------------------------------------------------
// There was no error store and no error telemetry at all — every one of the 13
// event types the app emitted was a happy-path one, so a failure could only be
// found by reading a table by hand.
//
// App-side failures now arrive as `app_error` events through the existing
// `ingest` function (no new table, nothing to migrate). This route unions them
// with the failures the backend already knew about but never surfaced: Groq
// key rejections, refused/failed OTP sends, and payments that did not settle.

export type ErrRow = {
  id: string;
  at: string;
  source: "app" | "llm" | "otp" | "payment";
  kind: string;
  message: string;
  detail?: string | null;
  subject?: string | null;   // device / agent / phone hash
  version?: string | null;
};

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));

export async function GET() {
  const bad = guard();
  if (bad) return bad;
  if (!dbConfigured()) return NextResponse.json({ rows: [], sources: {} });

  const sb = admin();
  const rows: ErrRow[] = [];
  const sources: Record<string, number> = { app: 0, llm: 0, otp: 0, payment: 0 };
  const notes: string[] = [];

  // 1. App-reported failures.
  try {
    const { data } = await sb
      .from("events")
      .select("id,device_id,event,props,app_version,created_at")
      .eq("event", "app_error")
      .order("created_at", { ascending: false })
      .limit(400);
    for (const e of (data as any[]) || []) {
      const p = e.props || {};
      rows.push({
        id: `app-${e.id ?? e.created_at}-${e.device_id ?? ""}`,
        at: e.created_at,
        source: "app",
        kind: String(p.kind ?? "error"),
        message: String(p.message ?? "Unknown failure"),
        detail: p.detail ? String(p.detail) : null,
        subject: e.device_id ?? null,
        version: e.app_version ?? null,
      });
      sources.app++;
    }
  } catch (e) {
    notes.push(`app: ${e}`);
  }

  // 2. Groq calls the provider rejected — the reason the assistant goes quiet.
  try {
    const { data } = await sb
      .from("key_usage")
      .select("id,key_index,model,ok,created_at")
      .eq("ok", false)
      .order("created_at", { ascending: false })
      .limit(200);
    for (const k of (data as any[]) || []) {
      rows.push({
        id: `llm-${k.id ?? k.created_at}`,
        at: k.created_at,
        source: "llm",
        kind: "groq call failed",
        message: `${k.model ?? "model"} rejected on key #${k.key_index}`,
        detail: null,
        subject: `key #${k.key_index}`,
        version: null,
      });
      sources.llm++;
    }
  } catch (e) {
    notes.push(`llm: ${e}`);
  }

  // 3. OTP sends that failed or were refused. Table name varies by schema
  // version, so try the known ones rather than 500 on a missing relation.
  for (const table of ["otp_requests", "otp_log", "otp_events"]) {
    try {
      const { data, error } = await sb
        .from(table)
        .select("*")
        .order("created_at", { ascending: false })
        .limit(200);
      if (error) continue;
      for (const o of (data as any[]) || []) {
        const status = String(o.status ?? "");
        if (!status || /^(sent|verified|ok|success)$/i.test(status)) continue;
        rows.push({
          id: `otp-${o.id ?? o.created_at}`,
          at: o.created_at,
          source: "otp",
          kind: `otp ${o.action ?? "send"}`,
          message: status,
          detail: null,
          subject: o.phone_hash ? String(o.phone_hash).slice(0, 10) + "…" : null,
          version: null,
        });
        sources.otp++;
      }
      break; // first table that answers wins
    } catch {
      /* try the next name */
    }
  }

  // 4. Payments that did not settle — money taken with no access granted is the
  // one failure here that costs someone real money.
  try {
    const { data } = await sb
      .from("payments")
      .select("id,agent_id,amount,status,provider,ref,created_at")
      .order("created_at", { ascending: false })
      .limit(200);
    for (const p of (data as any[]) || []) {
      if (!/fail|error|strand|cancel|refund/i.test(String(p.status))) continue;
      rows.push({
        id: `pay-${p.id}`,
        at: p.created_at,
        source: "payment",
        kind: `payment ${p.status}`,
        message: `${p.provider ?? "provider"} · ₹${p.amount}`,
        detail: p.ref ?? null,
        subject: p.agent_id ?? null,
        version: null,
      });
      sources.payment++;
    }
  } catch (e) {
    notes.push(`payment: ${e}`);
  }

  rows.sort((a, b) => (a.at < b.at ? 1 : -1));
  return NextResponse.json({ rows: rows.slice(0, 500), sources, notes });
}
