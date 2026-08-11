"use client";
import { useEffect, useMemo, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel } from "@/components/ui";
import { inr, num, when } from "@/lib/format";

type UserRow = {
  device_id: string;
  device_ids: string[];
  devices: number;
  name: string | null;
  mobile: string | null;
  agent_name: string | null;
  agent_id: string | null;
  region: string | null;
  accounts: number | null;
  collected: number;
  plan: string | null;
  sub_status: string | null;
  phone_verified: boolean;
  app_version: string | null;
  first_seen: string | null;
  last_seen: string | null;
  active: boolean;
};
type Labels = Record<string, string>;
type Data = { rows: UserRow[]; totals: { users?: number; accounts?: number; collected?: number; active?: number; subscribers?: number; phones?: number }; region_labels?: Labels };

type SortKey = "name" | "mobile" | "agent_name" | "devices" | "region" | "accounts" | "collected" | "plan" | "app_version" | "last_seen";
const COLS: { key: SortKey; label: string; num?: boolean }[] = [
  { key: "name", label: "Name" },
  { key: "mobile", label: "Mobile" },
  { key: "agent_name", label: "Agent" },
  { key: "devices", label: "Phones", num: true },
  { key: "region", label: "Region" },
  { key: "accounts", label: "Accounts", num: true },
  { key: "collected", label: "Collected", num: true },
  { key: "plan", label: "Plan" },
  { key: "app_version", label: "Version" },
  { key: "last_seen", label: "Last seen" },
];

export default function Users() {
  const [d, setD] = useState<Data | null>(null);
  const [labels, setLabels] = useState<Labels>({});
  const [q, setQ] = useState("");
  const [status, setStatus] = useState<"all" | "active" | "inactive">("all");
  const [plan, setPlan] = useState<"all" | "subscribed" | "none">("all");
  const [mode, setMode] = useState<"agents" | "regions">("agents");
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: "last_seen", dir: -1 });
  const [open, setOpen] = useState<UserRow | null>(null);

  useEffect(() => {
    fetch("/api/users").then((r) => r.json()).then((data: Data) => { setD(data); setLabels(data.region_labels || {}); }).catch(() => setD({ rows: [], totals: {} }));
  }, []);

  const regionOf = (sol: string | null) => (sol ? labels[sol] || null : null);

  const view = useMemo(() => {
    if (!d) return [];
    const needle = q.trim().toLowerCase();
    let rows = d.rows.filter((r) => {
      if (status === "active" && !r.active) return false;
      if (status === "inactive" && r.active) return false;
      if (plan === "subscribed" && !(r.sub_status && r.sub_status !== "expired")) return false;
      if (plan === "none" && r.sub_status && r.sub_status !== "expired") return false;
      if (needle) {
        const hay = [r.name, r.mobile, r.agent_name, r.agent_id, r.region, regionOf(r.region), r.plan, r.app_version].join(" ").toLowerCase();
        if (!hay.includes(needle)) return false;
      }
      return true;
    });
    const { key, dir } = sort;
    rows = [...rows].sort((a, b) => {
      const av = a[key], bv = b[key];
      if (av == null && bv == null) return 0;
      if (av == null) return 1;
      if (bv == null) return -1;
      if (typeof av === "number" && typeof bv === "number") return (av - bv) * dir;
      return String(av).localeCompare(String(bv)) * dir;
    });
    return rows;
  }, [d, q, status, plan, sort, labels]);

  const regions = useMemo(() => {
    const m = new Map<string, { region: string; agents: number; accounts: number; collected: number; active: number }>();
    for (const r of view) {
      const key = r.region || "—";
      const g = m.get(key) || { region: key, agents: 0, accounts: 0, collected: 0, active: 0 };
      g.agents++; g.accounts += r.accounts || 0; g.collected += r.collected; if (r.active) g.active++;
      m.set(key, g);
    }
    return [...m.values()].sort((a, b) => b.accounts - a.accounts);
  }, [view]);

  function toggleSort(key: SortKey) {
    setSort((s) => (s.key === key ? { key, dir: (s.dir * -1) as 1 | -1 } : { key, dir: key === "accounts" || key === "collected" ? -1 : 1 }));
  }

  async function saveLabel(sol: string, name: string) {
    const next = { ...labels };
    if (name.trim()) next[sol] = name.trim(); else delete next[sol];
    setLabels(next);
    await fetch("/api/config", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key: "region_labels", value: next }) });
  }

  function exportCsv() {
    const head = ["Name", "Mobile", "Agent", "Agent ID", "Region", "District", "Accounts", "Collected", "Plan", "Status", "Phone verified", "Version", "First seen", "Last seen"];
    const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const lines = view.map((r) =>
      [r.name, r.mobile, r.agent_name, r.agent_id, r.region, regionOf(r.region), r.accounts, r.collected, r.plan, r.active ? "active" : "dormant", r.phone_verified ? "yes" : "no", r.app_version, r.first_seen, r.last_seen].map(esc).join(",")
    );
    const csv = [head.map(esc).join(","), ...lines].join("\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    const a = document.createElement("a");
    a.href = url; a.download = `dop-users-${view.length}.csv`; a.click();
    URL.revokeObjectURL(url);
  }

  const t = d?.totals || {};

  return (
    <>
      <PageHead
        title="Users"
        subtitle="Every agent using the app — their book size, collections & plan"
        right={<span className="text-muted text-xs">{d ? `${view.length} of ${d.rows.length}` : ""}</span>}
      />

      {!d ? (
        <KpiSkeletons n={5} />
      ) : (
        <div className="grid gap-3.5 grid-cols-2 md:grid-cols-5">
          <Kpi label="Users (agents)" value={num(t.users)} sub={`${num(t.phones)} phones`} />
          <Kpi label="Active · 7d" value={num(t.active)} />
          <Kpi label="Accounts" value={num(t.accounts)} focal />
          <Kpi label="Collected" value={inr(t.collected)} />
          <Kpi label="Subscribers" value={num(t.subscribers)} />
        </div>
      )}

      <Card className="mt-3.5">
        <div className="flex flex-wrap items-center gap-2 mb-3">
          <input className="input max-w-xs" placeholder="Search name, mobile, agent, ID, region…" value={q} onChange={(e) => setQ(e.target.value)} />
          <Segmented value={status} onChange={(v) => setStatus(v as any)} options={[["all", "All"], ["active", "Active"], ["inactive", "Inactive"]]} />
          <Segmented value={plan} onChange={(v) => setPlan(v as any)} options={[["all", "Any plan"], ["subscribed", "Subscribed"], ["none", "No plan"]]} />
          <div className="ml-auto flex items-center gap-2">
            <Segmented value={mode} onChange={(v) => setMode(v as any)} options={[["agents", "Agents"], ["regions", "By region"]]} />
            <button className="btn btn-ghost" onClick={exportCsv} disabled={!view.length}>Export CSV</button>
          </div>
        </div>

        <div className="overflow-x-auto">
          {mode === "regions" ? (
            <table className="w-full text-[13px]">
              <thead>
                <tr>
                  <th className="lbl py-2 px-2 text-left">Region (SOL)</th>
                  <th className="lbl py-2 px-2 text-left">District</th>
                  <th className="lbl py-2 px-2 text-right">Agents</th>
                  <th className="lbl py-2 px-2 text-right">Active</th>
                  <th className="lbl py-2 px-2 text-right">Accounts</th>
                  <th className="lbl py-2 px-2 text-right">Collected</th>
                  <th className="lbl py-2 px-2 text-right">Avg / agent</th>
                </tr>
              </thead>
              <tbody>
                {regions.map((g) => (
                  <tr key={g.region} className="border-t border-line hover:bg-canvas/50">
                    <Cell className="font-mono text-xs font-bold">{g.region}</Cell>
                    <Cell>
                      {g.region === "—" ? <span className="text-faint">—</span> : (
                        <input
                          className="input py-1 w-36 text-[13px]"
                          placeholder="name this district"
                          defaultValue={labels[g.region] || ""}
                          onBlur={(e) => { if ((e.target.value.trim() || "") !== (labels[g.region] || "")) saveLabel(g.region, e.target.value); }}
                        />
                      )}
                    </Cell>
                    <Cell right>{num(g.agents)}</Cell>
                    <Cell right className="text-muted">{num(g.active)}</Cell>
                    <Cell right className="font-semibold">{num(g.accounts)}</Cell>
                    <Cell right>{g.collected ? inr(g.collected) : "—"}</Cell>
                    <Cell right className="text-muted">{num(Math.round(g.accounts / Math.max(1, g.agents)))}</Cell>
                  </tr>
                ))}
                {d && !regions.length && <tr><Cell className="text-muted">No data.</Cell></tr>}
              </tbody>
            </table>
          ) : (
            <table className="w-full text-[13px]">
              <thead>
                <tr>
                  {COLS.map((c) => (
                    <th key={c.key} onClick={() => toggleSort(c.key)}
                      className={`lbl py-2 px-2 whitespace-nowrap cursor-pointer select-none hover:text-ink ${c.num ? "text-right" : "text-left"}`}>
                      {c.label}<span className="ml-1 text-faint">{sort.key === c.key ? (sort.dir === 1 ? "▲" : "▼") : ""}</span>
                    </th>
                  ))}
                  <th className="lbl py-2 px-2 text-left">Status</th>
                </tr>
              </thead>
              <tbody>
                {!d
                  ? Array.from({ length: 6 }).map((_, i) => (
                      <tr key={i}><td colSpan={10} className="py-2 px-2"><Skel className="h-6 w-full" /></td></tr>
                    ))
                  : view.map((r) => (
                      <tr key={r.device_id} onClick={() => setOpen(r)} className="border-t border-line hover:bg-focal/20 cursor-pointer">
                        <Cell className="font-semibold">{r.name || <span className="text-faint">—</span>}</Cell>
                        <Cell className="font-mono text-xs">{r.mobile || <span className="text-faint">—</span>}</Cell>
                        <Cell>{r.agent_name || <span className="text-faint">—</span>}</Cell>
                        <Cell right>{r.devices > 1 ? <Pill tone="a">{r.devices}</Pill> : <span className="text-muted">{r.devices}</span>}</Cell>
                        <Cell className="font-mono text-xs">
                          {r.region ? <>{r.region}{regionOf(r.region) && <span className="text-muted font-sans"> · {regionOf(r.region)}</span>}</> : <span className="text-faint">—</span>}
                        </Cell>
                        <Cell right className="font-semibold">{r.accounts != null ? num(r.accounts) : <span className="text-faint">—</span>}</Cell>
                        <Cell right>{r.collected ? inr(r.collected) : <span className="text-faint">—</span>}</Cell>
                        <Cell>{r.plan ? <Pill tone={r.sub_status === "expired" ? "r" : "g"}>{r.plan}</Pill> : <span className="text-faint">—</span>}</Cell>
                        <Cell>{r.app_version || <span className="text-faint">—</span>}</Cell>
                        <Cell className="text-muted whitespace-nowrap">{r.last_seen ? when(r.last_seen) : "—"}</Cell>
                        <Cell><Pill tone={r.active ? "g" : "r"}>{r.active ? "active" : "dormant"}</Pill></Cell>
                      </tr>
                    ))}
              </tbody>
            </table>
          )}
          {d && mode === "agents" && !view.length && <Empty>No users match these filters.</Empty>}
        </div>
      </Card>

      {open && <AgentDrawer row={open} district={regionOf(open.region)} onClose={() => setOpen(null)} />}
    </>
  );
}

// --- Per-agent detail drawer ------------------------------------------------

type Detail = {
  events: { event: string; props: Record<string, unknown>; created_at: string }[];
  stats?: { events: number; lists: number; collected: number; first: string | null; last: string | null };
};

function AgentDrawer({ row, district, onClose }: { row: UserRow; district: string | null; onClose: () => void }) {
  const [det, setDet] = useState<Detail | null>(null);
  useEffect(() => {
    setDet(null);
    fetch(`/api/user?device=${encodeURIComponent(row.device_ids.join(","))}`).then((r) => r.json()).then(setDet).catch(() => setDet({ events: [] }));
    const onEsc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onEsc);
    return () => window.removeEventListener("keydown", onEsc);
  }, [row.device_id, onClose]);

  return (
    <div className="fixed inset-0 z-50 flex justify-end" onClick={onClose}>
      <div className="absolute inset-0 bg-ink/20" />
      <aside className="relative w-full max-w-[440px] bg-canvas h-full overflow-y-auto shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <div className="sticky top-0 bg-sidebar text-white px-5 py-4 flex items-start justify-between">
          <div>
            <div className="font-extrabold text-lg leading-tight">{row.name || row.agent_name || "Agent"}</div>
            <div className="text-white/60 text-xs mt-0.5">
              {row.mobile ? `+91 ${row.mobile} · ` : ""}{row.region ? `SOL ${row.region}${district ? ` · ${district}` : ""}` : "region unknown"}
            </div>
          </div>
          <button onClick={onClose} className="text-white/70 hover:text-white text-xl leading-none">✕</button>
        </div>

        <div className="p-5 flex flex-col gap-3.5">
          <div className="grid grid-cols-2 gap-3">
            <MiniStat label="Accounts maintained" value={row.accounts != null ? num(row.accounts) : "—"} focal />
            <MiniStat label="Collected (submitted)" value={row.collected ? inr(row.collected) : "—"} />
            <MiniStat label="Plan" value={row.plan || "—"} />
            <MiniStat label="Status" value={row.active ? "active" : "dormant"} />
          </div>

          <div className="card p-4 text-[13px]">
            <Row k="Agent name" v={row.agent_name || "—"} />
            <Row k="Agent ID" v={row.agent_id || "—"} mono />
            <Row k="Phone verified" v={row.phone_verified ? "yes" : "no"} />
            <Row k="App version" v={row.app_version || "—"} />
            <Row k="Phones" v={`${row.devices}${row.devices > 1 ? " (merged)" : ""}`} />
            <Row k="First seen" v={row.first_seen ? when(row.first_seen) : "—"} />
            <Row k="Last seen" v={row.last_seen ? when(row.last_seen) : "—"} />
            <Row k="Devices" v={row.device_ids.map((x) => x.slice(0, 8)).join(", ")} mono last />
          </div>

          <div className="card p-4">
            <div className="lbl mb-2">Recent activity {det?.stats ? `· ${num(det.stats.events)} events` : ""}</div>
            {!det ? (
              <div className="flex flex-col gap-1.5">{Array.from({ length: 6 }).map((_, i) => <Skel key={i} className="h-6 w-full" />)}</div>
            ) : det.events.length ? (
              <div className="flex flex-col gap-1.5 max-h-[46vh] overflow-y-auto">
                {det.events.map((e, i) => (
                  <div key={i} className="flex items-center justify-between gap-2 text-[12.5px]">
                    <Pill>{e.event}</Pill>
                    <span className="text-faint truncate flex-1">
                      {Object.entries(e.props || {}).map(([k, v]) => `${k}:${v}`).join(" · ")}
                    </span>
                    <span className="text-muted whitespace-nowrap">{when(e.created_at)}</span>
                  </div>
                ))}
              </div>
            ) : (
              <Empty>No activity recorded.</Empty>
            )}
          </div>
        </div>
      </aside>
    </div>
  );
}

function MiniStat({ label, value, focal }: { label: string; value: React.ReactNode; focal?: boolean }) {
  return (
    <div className={`card p-3.5 ${focal ? "!bg-focal" : ""}`}>
      <div className="lbl">{label}</div>
      <div className="text-[22px] font-extrabold leading-none mt-1.5">{value}</div>
    </div>
  );
}
function Row({ k, v, mono, last }: { k: string; v: React.ReactNode; mono?: boolean; last?: boolean }) {
  return (
    <div className={`flex items-center justify-between py-1.5 ${last ? "" : "border-b border-line"}`}>
      <span className="text-muted">{k}</span>
      <span className={mono ? "font-mono text-xs" : "font-semibold"}>{v}</span>
    </div>
  );
}

function Cell({ children, right, className = "" }: { children: React.ReactNode; right?: boolean; className?: string }) {
  return <td className={`py-2.5 px-2 ${right ? "text-right" : ""} ${className}`}>{children}</td>;
}
function Segmented({ value, onChange, options }: { value: string; onChange: (v: string) => void; options: [string, string][] }) {
  return (
    <div className="inline-flex rounded-xl border border-line overflow-hidden">
      {options.map(([v, label]) => (
        <button key={v} onClick={() => onChange(v)}
          className={`text-xs font-semibold px-3 py-2 transition ${value === v ? "bg-ink text-white" : "bg-white text-muted hover:bg-canvas"}`}>
          {label}
        </button>
      ))}
    </div>
  );
}
