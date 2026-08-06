import { NextRequest, NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";
import { admin, dbConfigured } from "@/lib/supabase";

export const dynamic = "force-dynamic";

// Releases / patches — visibility, record, and control.
// ---------------------------------------------------------------------------
// - Fleet adoption: which app_version every install is on (from telemetry), so
//   you can watch a Shorebird patch propagate.
// - Release log: a maintained record of every release/patch over time
//   (public.releases), optionally logged straight from a git commit.
// - Git: recent commits pulled from GitHub, SERVER-SIDE (any token stays off the
//   browser — see SECURITY_AUDIT S4). The service_role key is server-side too.
// - Control: the force-update gate in app_config (forces old installs to update)
//   + an optional non-forcing latest_version pointer.

const guard = () => (isAuthed() ? null : NextResponse.json({ error: "unauthorized" }, { status: 401 }));
const REPO = process.env.GITHUB_REPO || "naamyuvraj/DOP-Collect";

type Adoption = { app_version: string; devices: number; events: number; first_seen?: string; last_seen?: string };

// Prefer the v_app_versions view; if it isn't created yet, aggregate a capped
// slice of events in-process so the page still works before the SQL is run.
async function fleetAdoption(): Promise<{ rows: Adoption[]; needsSql: boolean }> {
  if (!dbConfigured()) return { rows: [], needsSql: false };
  const sb = admin();
  const view = await sb.from("v_app_versions").select("*");
  if (!view.error && view.data) return { rows: view.data as Adoption[], needsSql: false };

  // Fallback: aggregate from events (works now; the view scales better later).
  const { data } = await sb
    .from("events")
    .select("device_id,app_version,created_at")
    .not("app_version", "is", null)
    .order("created_at", { ascending: false })
    .limit(5000);
  const map = new Map<string, { devices: Set<string>; events: number; last?: string; first?: string }>();
  for (const e of (data as any[]) || []) {
    const v = e.app_version;
    if (!v) continue;
    const m = map.get(v) || { devices: new Set<string>(), events: 0 };
    m.devices.add(e.device_id);
    m.events++;
    m.last = m.last && m.last > e.created_at ? m.last : e.created_at;
    m.first = m.first && m.first < e.created_at ? m.first : e.created_at;
    map.set(v, m);
  }
  const rows = [...map.entries()]
    .map(([app_version, m]) => ({ app_version, devices: m.devices.size, events: m.events, last_seen: m.last, first_seen: m.first }))
    .sort((a, b) => (a.last_seen! < b.last_seen! ? 1 : -1));
  return { rows, needsSql: true };
}

async function gitCommits() {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/commits?per_page=15`, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "dop-dashboard",
        ...(process.env.GITHUB_TOKEN ? { Authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {}),
      },
      next: { revalidate: 300 }, // cache 5 min — GitHub unauth limit is 60/hr
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) return { commits: [], gitError: `GitHub ${res.status}` };
    const data = (await res.json()) as any[];
    return {
      commits: data.map((c) => ({
        sha: c.sha as string,
        short: (c.sha as string).slice(0, 7),
        message: (c.commit?.message || "").split("\n")[0],
        author: c.commit?.author?.name || c.author?.login || "?",
        date: c.commit?.author?.date,
        url: c.html_url,
      })),
      gitError: null as string | null,
    };
  } catch (e) {
    return { commits: [], gitError: `git fetch failed: ${String(e)}` };
  }
}

export async function GET() {
  const bad = guard();
  if (bad) return bad;
  try {
    const sb = admin();
    const [rel, cfg, fleet, git] = await Promise.all([
      sb.from("releases").select("*").order("created_at", { ascending: false }).limit(100),
      sb.from("app_config").select("key,value").in("key", ["force_update", "latest_version"]),
      fleetAdoption(),
      gitCommits(),
    ]);
    const config: Record<string, unknown> = {};
    for (const r of cfg.data || []) config[(r as any).key] = (r as any).value;
    return NextResponse.json({
      releases: rel.error ? [] : rel.data || [],
      releasesNeedsSql: !!rel.error, // table not created yet
      adoption: fleet.rows,
      adoptionNeedsSql: fleet.needsSql,
      force_update: config.force_update ?? { version: "", message: "", enabled: false },
      latest_version: config.latest_version ?? "",
      commits: git.commits,
      gitError: git.gitError,
      repo: REPO,
    });
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 500 });
  }
}

// POST -> log a release/patch
export async function POST(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const b = await req.json().catch(() => ({}));
  if (!String(b.version || "").trim())
    return NextResponse.json({ ok: false, error: "version is required" }, { status: 400 });
  const { error } = await admin().from("releases").insert({
    version: String(b.version).trim(),
    kind: b.kind === "release" ? "release" : "patch",
    channel: b.channel || "stable",
    shorebird_patch: b.shorebird_patch != null && b.shorebird_patch !== "" ? Number(b.shorebird_patch) : null,
    git_sha: b.git_sha || null,
    notes: b.notes || null,
  });
  return NextResponse.json({
    ok: !error,
    error: error?.message
      ? `${error.message}${/relation .* does not exist|schema cache/i.test(error.message) ? " — run admin/schema_releases.sql first." : ""}`
      : undefined,
  });
}

// PATCH -> edit a release by id
export async function PATCH(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const b = await req.json().catch(() => ({}));
  if (!b.id) return NextResponse.json({ ok: false, error: "id required" }, { status: 400 });
  const patch: Record<string, unknown> = {};
  for (const k of ["version", "kind", "channel", "notes", "git_sha"]) if (b[k] !== undefined) patch[k] = b[k];
  if (b.shorebird_patch !== undefined)
    patch.shorebird_patch = b.shorebird_patch === "" || b.shorebird_patch == null ? null : Number(b.shorebird_patch);
  const { error } = await admin().from("releases").update(patch).eq("id", b.id);
  return NextResponse.json({ ok: !error, error: error?.message });
}

// DELETE -> remove a release by id
export async function DELETE(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const b = await req.json().catch(() => ({}));
  if (!b.id) return NextResponse.json({ ok: false, error: "id required" }, { status: 400 });
  const { error } = await admin().from("releases").delete().eq("id", b.id);
  return NextResponse.json({ ok: !error, error: error?.message });
}

// PUT -> update the control levers in app_config (force_update | latest_version)
export async function PUT(req: NextRequest) {
  const bad = guard();
  if (bad) return bad;
  const { key, value } = await req.json().catch(() => ({}));
  if (key !== "force_update" && key !== "latest_version")
    return NextResponse.json({ ok: false, error: "unknown config key" }, { status: 400 });
  const { error } = await admin()
    .from("app_config")
    .upsert({ key, value, updated_at: new Date().toISOString() });
  return NextResponse.json({ ok: !error, error: error?.message });
}
