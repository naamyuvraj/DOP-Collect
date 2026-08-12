"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Pill, Skel, Td, Th } from "@/components/ui";
import { num, when } from "@/lib/format";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";

type Adoption = { app_version: string; devices: number; events: number; last_seen?: string };
type Release = {
  id: number; version: string; kind: string; channel: string;
  shorebird_patch: number | null; git_sha: string | null; notes: string | null; created_at: string;
};
type Commit = { sha: string; short: string; message: string; author: string; date: string; url: string };
type ForceUpdate = { version: string; message: string; enabled: boolean };
type Data = {
  releases: Release[]; releasesNeedsSql: boolean;
  adoption: Adoption[]; adoptionNeedsSql: boolean;
  force_update: ForceUpdate; latest_version: string; version_baseline: string;
};
type Git = { commits: Commit[]; gitError: string | null; repo: string };

const emptyForm = { version: "", kind: "patch", shorebird_patch: "", git_sha: "", notes: "" };

// Compare "0.9.43+16"-style versions numerically. a >= b ?
const verParts = (v: string) => (v || "").split(/[.+]/).map((x) => parseInt(x, 10) || 0);
function verGte(a: string, b: string) {
  const pa = verParts(a), pb = verParts(b), n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) { const x = pa[i] || 0, y = pb[i] || 0; if (x !== y) return x > y; }
  return true;
}

function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <button onClick={() => onChange(!on)} className={`w-12 h-7 rounded-full transition relative shrink-0 ${on ? "bg-red" : "bg-line"}`}>
      <span className={`absolute top-1 w-5 h-5 rounded-full bg-white shadow transition-all ${on ? "left-6" : "left-1"}`} />
    </button>
  );
}

export default function Releases() {
  const [d, setD] = useState<Data | null>(() => peekCached<Data>("releases"));
  const [git, setGit] = useState<Git | null>(() => peekCached<Git>("git")); // fetched separately so GitHub never blocks the page
  const [form, setForm] = useState<typeof emptyForm>({ ...emptyForm });
  const [flash, setFlash] = useState("");
  const [showAll, setShowAll] = useState(false); // reveal versions below the baseline

  async function load() {
    const data = await fetch("/api/releases").then((r) => r.json());
    setCached("releases", data);
    setD(data);
  }
  useEffect(() => {
    if (!isFresh("releases")) load();
    if (!isFresh("git")) fetch("/api/git").then((r) => r.json()).then((g) => { setCached("git", g); setGit(g); }).catch(() => setGit({ commits: [], gitError: "git unavailable", repo: "" }));
  }, []);
  function say(m: string) { setFlash(m); setTimeout(() => setFlash(""), 2000); }

  async function addRelease() {
    if (!form.version.trim()) return say("Enter a version.");
    const res = await fetch("/api/releases", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(form),
    }).then((r) => r.json());
    if (res.error) return say(res.error);
    setForm({ ...emptyForm });
    await load();
    say("Logged.");
  }
  async function delRelease(id: number) {
    await fetch("/api/releases", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id }) });
    await load();
    say("Deleted.");
  }
  async function setControl(key: "force_update" | "latest_version" | "version_baseline", value: unknown) {
    setD((p) => (p ? { ...p, [key]: value } : p));
    await fetch("/api/releases", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key, value }) });
    say("Saved.");
  }
  function logFromCommit(c: Commit) {
    setForm({ ...form, git_sha: c.short, notes: form.notes || c.message });
    document.getElementById("rel-form")?.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  if (!d) {
    return (
      <>
        <PageHead title="Releases & Patches" subtitle="Watch versions roll out, keep a record, and gate old installs" />
        <Card title="Fleet by version">
          <div className="flex flex-col gap-2">
            {Array.from({ length: 5 }).map((_, i) => <Skel key={i} className="h-8 w-full" />)}
          </div>
        </Card>
        <div className="grid gap-3.5 mt-3.5 lg:grid-cols-[1fr_1fr]">
          <Card title="Release log"><Skel className="h-40 w-full" /></Card>
          <Card title="Recent commits"><Skel className="h-40 w-full" /></Card>
        </div>
      </>
    );
  }

  const baseline = d.version_baseline || "";
  const newest = d.adoption.reduce((m, a) => (!m || verGte(a.app_version, m) ? a.app_version : m), "");
  const shownAdoption = showAll || !baseline ? d.adoption : d.adoption.filter((a) => verGte(a.app_version, baseline));
  const hiddenVersions = d.adoption.length - shownAdoption.length;
  const shownReleases = showAll || !baseline ? d.releases : d.releases.filter((r) => verGte(r.version, baseline));
  const maxDevices = Math.max(1, ...shownAdoption.map((a) => a.devices));
  const fu = d.force_update || { version: "", message: "", enabled: false };

  return (
    <>
      <PageHead
        title="Releases & Patches"
        subtitle="Watch versions roll out, keep a record, and gate old installs"
        right={<span className="text-muted text-xs">{flash}</span>}
      />

      {/* Fleet adoption */}
      <Card
        title="Fleet by version"
        right={
          <div className="flex items-center gap-2 text-xs">
            {baseline ? (
              <span className="text-muted">tracking from <b className="font-mono">{baseline}</b></span>
            ) : (
              <span className="text-muted">all versions</span>
            )}
            {baseline && hiddenVersions > 0 && (
              <button className="underline text-muted" onClick={() => setShowAll((v) => !v)}>
                {showAll ? "hide older" : `show ${hiddenVersions} older`}
              </button>
            )}
            {newest && (
              <button className="btn btn-ghost py-1 px-2 text-xs" title="Hide every version below the current one" onClick={() => { setShowAll(false); setControl("version_baseline", newest); }}>
                Track from {newest}
              </button>
            )}
            {baseline && (
              <button className="underline text-faint" onClick={() => setControl("version_baseline", "")}>reset</button>
            )}
          </div>
        }
      >
        {d.adoptionNeedsSql && (
          <div className="text-amber text-xs font-semibold mb-2">
            Showing a live sample — run <code>admin/schema_releases.sql</code> for the full, scalable view.
          </div>
        )}
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead><tr><Th>Version</Th><Th>Installs</Th><Th>Events</Th><Th>Share</Th><Th>Last seen</Th></tr></thead>
            <tbody>
              {shownAdoption.map((a, i) => (
                <tr key={a.app_version}>
                  <Td className="font-mono text-xs font-bold">
                    {a.app_version} {i === 0 && <Pill tone="g">latest seen</Pill>}
                  </Td>
                  <Td>{num(a.devices)}</Td>
                  <Td className="text-muted">{num(a.events)}</Td>
                  <Td>
                    <div className="h-2 rounded-full bg-line w-32 overflow-hidden">
                      <div className="h-full bg-green rounded-full" style={{ width: `${(a.devices / maxDevices) * 100}%` }} />
                    </div>
                  </Td>
                  <Td className="text-muted text-xs whitespace-nowrap">{a.last_seen ? when(a.last_seen) : "—"}</Td>
                </tr>
              ))}
              {!shownAdoption.length && <tr><Td className="text-muted">{d.adoption.length ? "No versions at/after the baseline yet." : "No version telemetry yet."}</Td></tr>}
            </tbody>
          </table>
        </div>
      </Card>

      <div className="grid gap-3.5 mt-3.5 lg:grid-cols-[1fr_1fr]">
        {/* Release log + add form */}
        <Card title="Release log">
          <div id="rel-form" className="rounded-xl border border-line p-3 mb-3">
            <div className="flex gap-2 mb-2">
              <input className="input" placeholder="version e.g. 0.9.44+17" value={form.version} onChange={(e) => setForm({ ...form, version: e.target.value })} />
              <select className="input w-28" value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
                <option value="patch">patch</option>
                <option value="release">release</option>
              </select>
            </div>
            <div className="flex gap-2 mb-2">
              <input className="input w-32" placeholder="patch #" value={form.shorebird_patch} onChange={(e) => setForm({ ...form, shorebird_patch: e.target.value })} />
              <input className="input" placeholder="git sha" value={form.git_sha} onChange={(e) => setForm({ ...form, git_sha: e.target.value })} />
            </div>
            <textarea className="input min-h-[60px] mb-2" placeholder="what changed" value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
            <button className="btn w-full" onClick={addRelease}>Log release / patch</button>
          </div>
          {d.releasesNeedsSql && (
            <div className="text-amber text-xs font-semibold mb-2">Run <code>admin/schema_releases.sql</code> to enable the record.</div>
          )}
          <div className="flex flex-col gap-2 max-h-[360px] overflow-y-auto">
            {shownReleases.map((r) => (
              <div key={r.id} className="rounded-xl border border-line p-2.5 flex items-start justify-between gap-2">
                <div>
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-xs font-bold">{r.version}</span>
                    <Pill tone={r.kind === "release" ? "b" : "g"}>{r.kind}</Pill>
                    {r.shorebird_patch != null && <span className="text-muted text-xs">patch #{r.shorebird_patch}</span>}
                    {r.git_sha && <span className="text-faint text-xs font-mono">{r.git_sha}</span>}
                  </div>
                  {r.notes && <div className="text-muted text-xs mt-1">{r.notes}</div>}
                  <div className="text-faint text-[11px] mt-1">{when(r.created_at)}</div>
                </div>
                <button className="btn btn-ghost py-1 px-2 text-xs" onClick={() => delRelease(r.id)}>🗑</button>
              </div>
            ))}
            {!shownReleases.length && <Empty>{d.releases.length ? "No releases at/after the baseline." : "No releases logged yet."}</Empty>}
          </div>
        </Card>

        {/* Git history — loaded separately so GitHub never blocks the page */}
        <Card title="Recent commits" right={<span className="text-faint text-xs font-mono">{git?.repo || ""}</span>}>
          {git?.gitError && <div className="text-red text-xs font-semibold mb-2">{git.gitError}</div>}
          <div className="flex flex-col gap-1.5 max-h-[440px] overflow-y-auto">
            {!git ? (
              Array.from({ length: 6 }).map((_, i) => <Skel key={i} className="h-10 w-full" />)
            ) : (
              <>
                {git.commits.map((c) => (
                  <div key={c.sha} className="rounded-lg hover:bg-canvas/60 p-2 flex items-center justify-between gap-2">
                    <div className="min-w-0">
                      <div className="text-[13px] truncate">{c.message}</div>
                      <div className="text-faint text-[11px]">
                        <span className="font-mono">{c.short}</span> · {c.author} · {c.date ? when(c.date) : ""}
                      </div>
                    </div>
                    <button className="btn btn-ghost py-1 px-2 text-xs whitespace-nowrap" onClick={() => logFromCommit(c)}>Log ↑</button>
                  </div>
                ))}
                {!git.commits.length && !git.gitError && <Empty>No commits.</Empty>}
              </>
            )}
          </div>
        </Card>
      </div>

      {/* Update control */}
      <Card title="Force-update gate" className="mt-3.5">
        <p className="text-muted text-xs mb-3">
          The real control lever over patches: installs on a version <b>below</b> the minimum get a blocking
          “please update” screen on next launch. The app reads this live — no rebuild needed. (Building/pushing a
          Shorebird OTA patch itself is done from your dev machine with <code>shorebird patch</code>.)
        </p>
        <div className="grid sm:grid-cols-2 gap-3">
          <div>
            <label className="lbl">Minimum version</label>
            <input className="input mt-1" placeholder="e.g. 0.9.43+16" value={fu.version}
              onChange={(e) => setD({ ...d, force_update: { ...fu, version: e.target.value } })} />
          </div>
          <div>
            <label className="lbl">Non-forcing “latest” pointer</label>
            <input className="input mt-1" placeholder="e.g. 0.9.44+17" value={d.latest_version || ""}
              onChange={(e) => setD({ ...d, latest_version: e.target.value })}
              onBlur={(e) => setControl("latest_version", e.target.value)} />
          </div>
        </div>
        <label className="lbl mt-3 block">Message</label>
        <input className="input mt-1" placeholder="Please update to continue" value={fu.message}
          onChange={(e) => setD({ ...d, force_update: { ...fu, message: e.target.value } })} />
        <div className="flex items-center justify-between mt-4">
          <div className="flex items-center gap-3">
            <span className="text-sm font-semibold">Force-update {fu.enabled ? "ON" : "off"}</span>
            <Toggle on={!!fu.enabled} onChange={(v) => setControl("force_update", { ...fu, enabled: v })} />
          </div>
          <button className="btn" onClick={() => setControl("force_update", fu)}>Save gate</button>
        </div>
      </Card>
    </>
  );
}
