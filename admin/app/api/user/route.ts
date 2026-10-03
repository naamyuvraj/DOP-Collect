import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// One agent's activity, for the Users-tab detail drawer. The profile fields come
// from the row the client already has; here we return the recent event stream +
// the sync/collection history so you can see what an agent has been doing.
export async function GET(req: NextRequest) {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  // Accept one device or an agent's several phones (comma-separated).
  const ids = (req.nextUrl.searchParams.get("device") || "")
    .split(",").map((s) => s.trim().slice(0, 64)).filter(Boolean).slice(0, 8);
  if (!ids.length) return NextResponse.json({ error: "device required" }, { status: 400 });
  if (!dbConfigured()) return NextResponse.json({ events: [], syncs: [], collections: [] });

  try {
    const sb = admin();
    const { data, error } = await sb
      .from("events")
      .select("event,props,app_version,created_at")
      .in("device_id", ids)
      .order("created_at", { ascending: false })
      .limit(200);
    if (error) return NextResponse.json({ error: error.message }, { status: 200 });
    const events = (data as any[]) || [];

    const syncs = events
      .filter((e) => e.event === "sync_done" && e.props?.accounts != null)
      .map((e) => ({ accounts: Number(e.props.accounts) || 0, at: e.created_at }));
    const collections = events
      .filter((e) => e.event === "list_submitted" || e.event === "lot_created")
      .map((e) => ({
        kind: e.event,
        amount: Number(e.props?.amount) || 0,
        accounts: Number(e.props?.accounts) || 0,
        at: e.created_at,
      }));

    const stats = {
      events: events.length,
      lists: collections.length,
      collected: collections.filter((c) => c.kind === "list_submitted").reduce((s, c) => s + c.amount, 0),
      first: events.length ? events[events.length - 1].created_at : null,
      last: events.length ? events[0].created_at : null,
    };

    return NextResponse.json({ events: events.slice(0, 40), syncs, collections, stats });
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 200 });
  }
}
