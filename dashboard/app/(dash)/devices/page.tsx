"use client";
import { useEffect, useMemo, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel } from "@/components/ui";
import { inr, num, when } from "@/lib/format";

type UserRow = {
  device_id: string;
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
type Data = { rows: UserRow[]; totals: { users?: number; accounts?: number; collected?: number; active?: number; subscribers?: number } };

type SortKey = "name" | "mobile" | "agent_name" | "region" | "accounts" | "collected" | "plan" | "app_version" | "last_seen";
const COLS: { key: SortKey; label: string; num?: boolean }[] = [
  { key: "name", label: "Name" },
  { key: "mobile", label: "Mobile" },
  { key: "agent_name", label: "Agent" },
  { key: "region", label: "Region (SOL)" },
  { key: "accounts", label: "Accounts", num: true },
  { key: "collected", label: "Collected", num: true },
  { key: "plan", label: "Plan" },
  { key: "app_version", label: "Version" },
  { key: "last_seen", label: "Last seen" },
];

export default function Users() {
  const [d, setD] = useState<Data | null>(null);
  const [q, setQ] = useState("");
  const [status, setStatus] = useState<"all" | "active" | "inactive">("all");
  const [plan, setPlan] = useState<"all" | "subscribed" | "none">("all");
  const [mode, setMode] = useState<"agents" | "regions">("agents");
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: "last_seen", dir: -1 });

  useEffect(() => {
    fetch("/api/users").then((r) => r.json()).then(setD).catch(() => setD({ rows: [], totals: {} }));
  }, []);

  const view = useMemo(() => {
    if (!d) return [];
    const needle = q.trim().toLowerCase();
    let rows = d.rows.filter((r) => {
      if (status === "active" && !r.active) return false;
      if (status === "inactive" && r.active) return false;
      if (plan === "subscribed" && !(r.sub_status && r.sub_status !== "expired")) return false;
      if (plan === "none" && r.sub_status && r.sub_status !== "expired") return false;
      if (needle) {
        const hay = [r.name, r.mobile, r.agent_name, r.agent_id, r.region, r.plan, r.app_version].join(" ").toLowerCase();
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
  }, [d, q, status, plan, sort]);

  // Per-region rollup of the filtered set.
  const regions = useMemo(() => {
    const m = new Map<string, { region: string; agents: number; accounts: number; collected: number; active: number }>();
    for (const r of view) {
      const key = r.region || "—";
      const g = m.get(key) || { region: key, agents: 0, accounts: 0, collected: 0, active: 0 };
      g.agents++;
      g.accounts += r.accounts || 0;
      g.collected += r.collected;
      if (r.active) g.active++;
      m.set(key, g);
    }
    return [...m.values()].sort((a, b) => b.accounts - a.accounts);
  }, [view]);

  function toggleSort(key: SortKey) {
    setSort((s) => (s.key === key ? { key, dir: (s.dir * -1) as 1 | -1 } : { key, dir: key === "accounts" || key === "collected" ? -1 : 1 }));
  }

  function exportCsv() {
    const head = ["Name", "Mobile", "Agent", "Agent ID", "Region", "Accounts", "Collected", "Plan", "Status", "Phone verified", "Version", "First seen", "Last seen"];
    const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const lines = view.map((r) =>
      [r.name, r.mobile, r.agent_name, r.agent_id, r.region, r.accounts, r.collected, r.plan, r.active ? "active" : "dormant", r.phone_verified ? "yes" : "no", r.app_version, r.first_seen, r.last_seen].map(esc).join(",")
    );
    const csv = [head.map(esc).join(","), ...lines].join("\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `dop-users-${view.length}.csv`;
    a.click();
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
          <Kpi label="Users" value={num(t.users)} />
          <Kpi label="Active · 7d" value={num(t.active)} />
          <Kpi label="Accounts" value={num(t.accounts)} focal />
          <Kpi label="Collected" value={inr(t.collected)} />
          <Kpi label="Subscribers" value={num(t.subscribers)} />
        </div>
      )}

      <Card className="mt-3.5">
        {/* Toolbar */}
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
                  <th className="lbl py-2 px-2 text-right">Agents</th>
                  <th className="lbl py-2 px-2 text-right">Active</th>
                  <th className="lbl py-2 px-2 text-right">Accounts</th>
                  <th className="lbl py-2 px-2 text-right">Collected</th>
                  <th className="lbl py-2 px-2 text-right">Avg acc / agent</th>
                </tr>
              </thead>
              <tbody>
                {regions.map((g) => (
                  <tr key={g.region} className="border-t border-line hover:bg-canvas/50">
                    <Cell className="font-mono text-xs font-bold">{g.region}</Cell>
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
                      {c.label}
                      <span className="ml-1 text-faint">{sort.key === c.key ? (sort.dir === 1 ? "▲" : "▼") : ""}</span>
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
                      <tr key={r.device_id} className="border-t border-line hover:bg-canvas/50">
                        <Cell className="font-semibold">{r.name || <span className="text-faint">—</span>}</Cell>
                        <Cell className="font-mono text-xs">{r.mobile || <span className="text-faint">—</span>}</Cell>
                        <Cell>{r.agent_name || <span className="text-faint">—</span>}</Cell>
                        <Cell className="font-mono text-xs">{r.region || <span className="text-faint">—</span>}</Cell>
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
    </>
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
