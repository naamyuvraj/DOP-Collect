import { NextRequest, NextResponse } from "next/server";
import { revalidatePath } from "next/cache";
import { isAuthed } from "@/lib/auth";

export const dynamic = "force-dynamic";

/**
 * Drop the ISR cache for one page, so a Reload button actually reloads.
 *
 * The server-rendered tabs sit behind `export const revalidate = 60`, so
 * router.refresh() alone can re-run the render and still be handed the cached
 * payload — the button would look like it did nothing for up to a minute.
 */
const ALLOWED = new Set(["/", "/payments", "/activity", "/devices", "/releases", "/regions"]);

export async function POST(req: NextRequest) {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { path } = await req.json().catch(() => ({ path: "" }));
  // Allow-list: revalidatePath takes a caller-supplied string, and an open one
  // lets anyone with a session bust arbitrary cache entries.
  if (!ALLOWED.has(path)) return NextResponse.json({ ok: false, error: "unknown path" }, { status: 400 });
  revalidatePath(path);
  return NextResponse.json({ ok: true, path });
}
