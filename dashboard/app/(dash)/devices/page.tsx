"use client";
import { useEffect, useMemo, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel } from "@/components/ui";
import { inr, num, shortId, when } from "@/lib/format";

type UserRow = {
  device_id: string;
  name: string | null;
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

type SortKey = "name" | "agent_name" | "region" | "accounts" | "collected" | "plan" | "app_version" | "last_seen";
const COLS: { key: SortKey; label: string; num?: boolean }[] = [
  { key: "name", label: "Name" },
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
        const hay = [r.name, r.agent_name, r.agent_id, r.region, r.plan, r.app_version].join(" ").toLowerCase();
        if (!hay.includes(needle)) return false;
      }
      return true;
    });
    const { key, dir } = sort;
    rows = [...rows].sort((a, b) => {
      const av = a[key], bv = b[key];
      if (av == null && bv == null) return 0;
      if (av == null) return 1; // nulls last
      if (bv == null) return -1;
      if (typeof av === "number" && typeof bv === "number") return (av - bv) * dir;
      return String(av).localeCompare(String(bv)) * dir;
    });
    return rows;
  }, [d, q, status, plan, sort]);

  function toggleSort(key: SortKey) {
    setSort((s) => (s.key === key ? { key, dir: (s.dir * -1) as 1 | -1 } : { key, dir: key === "accounts" || key === "collected" ? -1 : 1 }));
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
          <input
            className="input max-w-xs"
            placeholder="Search name, agent, ID, region…"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
          <Segmented value={status} onChange={(v) => setStatus(v as any)} options={[["all", "All"], ["active", "Active"], ["inactive", "Inactive"]]} />
          <Segmented value={plan} onChange={(v) => setPlan(v as any)} options={[["all", "Any plan"], ["subscribed", "Subscribed"], ["none", "No plan"]]} />
          {(q || status !== "all" || plan !== "all") && (
            <button className="text-xs text-muted underline" onClick={() => { setQ(""); setStatus("all"); setPlan("all"); }}>
              clear
            </button>
          )}
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                {COLS.map((c) => (
                  <th
                    key={c.key}
                    onClick={() => toggleSort(c.key)}
                    className={`lbl py-2 px-2 whitespace-nowrap cursor-pointer select-none hover:text-ink ${c.num ? "text-right" : "text-left"}`}
                  >
                    {c.label}
                    <span className="ml-1 text-faint">{sort.key === c.key ? (sort.dir === 1 ? "▲" : "▼") : ""}</span>
                  </th>
                ))}
                <th className="lbl py-2 px-2 text-left">Phone</th>
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
                      <Cell>{r.agent_name || <span className="text-faint">—</span>}</Cell>
                      <Cell className="font-mono text-xs">{r.region || <span className="text-faint">—</span>}</Cell>
                      <Cell right className="font-semibold">{r.accounts != null ? num(r.accounts) : <span className="text-faint">—</span>}</Cell>
                      <Cell right>{r.collected ? inr(r.collected) : <span className="text-faint">—</span>}</Cell>
                      <Cell>{r.plan ? <Pill tone={r.sub_status === "expired" ? "r" : "g"}>{r.plan}</Pill> : <span className="text-faint">—</span>}</Cell>
                      <Cell>{r.app_version || <span className="text-faint">—</span>}</Cell>
                      <Cell className="text-muted whitespace-nowrap">{r.last_seen ? when(r.last_seen) : "—"}</Cell>
                      <Cell>{r.phone_verified ? <Pill tone="g">verified</Pill> : <span className="text-faint">—</span>}</Cell>
                      <Cell><Pill tone={r.active ? "g" : "r"}>{r.active ? "active" : "dormant"}</Pill></Cell>
                    </tr>
                  ))}
            </tbody>
          </table>
          {d && !view.length && <Empty>No users match these filters.</Empty>}
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
        <button
          key={v}
          onClick={() => onChange(v)}
          className={`text-xs font-semibold px-3 py-2 transition ${value === v ? "bg-ink text-white" : "bg-white text-muted hover:bg-canvas"}`}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
