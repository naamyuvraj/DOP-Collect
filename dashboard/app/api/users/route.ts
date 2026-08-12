import { NextResponse } from "next/server";
import { unstable_cache } from "next/cache";
import { isAuthed } from "@/lib/auth";
import { dbConfigured } from "@/lib/supabase";
import { computeUsers } from "@/lib/users";

export const dynamic = "force-dynamic";
export type { UserRow } from "@/lib/users";

// Agent-level rows + totals for the Users tab. All the logic lives in lib/users
// (shared with the Overview so every number agrees). Short cache; telemetry has
// no write hook to bust the tag, so we lean on time.
const readUsers = unstable_cache(computeUsers, ["users-data"], { revalidate: 15, tags: ["users"] });

export async function GET() {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!dbConfigured()) return NextResponse.json({ rows: [], totals: {} });
  try {
    return NextResponse.json(await readUsers());
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 500 });
  }
}
