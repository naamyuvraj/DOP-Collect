import { NextResponse } from "next/server";
import { isAuthed } from "@/lib/auth";

export const dynamic = "force-dynamic";

// Recent git commits, fetched separately from /api/releases so a slow (or
// cache-missing) GitHub call never blocks the Releases page's own data. The
// token, if any, stays server-side (SECURITY_AUDIT S4). Public repo needs none.
const REPO = process.env.GITHUB_REPO || "naamyuvraj/DOP-Collect";

export async function GET() {
  if (!isAuthed()) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
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
    if (!res.ok) return NextResponse.json({ commits: [], gitError: `GitHub ${res.status}`, repo: REPO });
    const data = (await res.json()) as any[];
    return NextResponse.json({
      repo: REPO,
      gitError: null,
      commits: data.map((c) => ({
        sha: c.sha as string,
        short: (c.sha as string).slice(0, 7),
        message: (c.commit?.message || "").split("\n")[0],
        author: c.commit?.author?.name || c.author?.login || "?",
        date: c.commit?.author?.date,
        url: c.html_url,
      })),
    });
  } catch (e) {
    return NextResponse.json({ commits: [], gitError: `git fetch failed: ${String(e)}`, repo: REPO });
  }
}
