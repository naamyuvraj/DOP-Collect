"use client";
import { useEffect, useMemo, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel } from "@/components/ui";
import { inr, num, when } from "@/lib/format";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";

type UserRow = {
  device_id: string;
  device_ids: string[];
  devices: number;
  signed_in: number;
  name: string | null;
  mobile: string | null;
  agent_id: string | null;
  model: string | null;
  region: string | null;
  accounts: number | null;
  value: number | null;
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
type Data = { rows: UserRow[]; totals: { agents?: number; verified?: number; active?: number; installs?: number; accounts?: number; value?: number; collected?: number; lists?: number; subscribers?: number }; region_labels?: Labels };

type SortKey = "name" | "mobile" | "signed_in" | "region" | "accounts" | "value" | "collected" | "plan" | "app_version" | "last_seen";
const COLS: { key: SortKey; label: string; num?: boolean }[] = [
  { key: "name", label: "Agent name" },
  { key: "mobile", label: "Mobile" },
  { key: "signed_in", label: "Phones", num: true },
  { key: "region", label: "Region" },
  { key: "accounts", label: "Accounts", num: true },
  { key: "value", label: "Monthly ₹", num: true },
  { key: "collected", label: "Collected", num: true },
  { key: "plan", label: "Plan" },
  { key: "app_version", label: "Version" },
  { key: "last_seen", label: "Last seen" },
];

export default function Users() {
  const [d, setD] = useState<Data | null>(() => peekCached<Data>("users"));
  const [labels, setLabels] = useState<Labels>(() => peekCached<Data>("users")?.region_labels || {});
  const [q, setQ] = useState("");
  const [status, setStatus] = useState<"all" | "active" | "inactive">("all");
  const [plan, setPlan] = useState<"all" | "subscribed" | "none">("all");
  const [verified, setVerified] = useState<"all" | "verified" | "unverified">("all");
  const [mode, setMode] = useState<"agents" | "regions">("agents");
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: "last_seen", dir: -1 });
  const [open, setOpen] = useState<UserRow | null>(null);

  useEffect(() => {
    if (isFresh("users")) return; // shown from cache; still fresh — no refetch
    fetch("/api/users").then((r) => r.json()).then((data: Data) => { setCached("users", data); setD(data); setLabels(data.region_labels || {}); }).catch(() => { if (!peekCached("users")) setD({ rows: [], totals: {} }); });
  }, []);

  const regionOf = (sol: string | null) => (sol ? labels[sol] || null : null);

  /// Refetch past the client cache. An admin edit has to be visible at once —
  /// waiting out the freshness window is what makes a save look like it failed.
  async function reload() {
    try {
      const data: Data = await fetch("/api/users", { cache: "no-store" }).then((r) => r.json());
      setCached("users", data);
      setD(data);
      setLabels(data.region_labels || {});
    } catch {/* keep what's on screen */}
  }

  const view = useMemo(() => {
    if (!d) return [];
    const needle = q.trim().toLowerCase();
    let rows = d.rows.filter((r) => {
      if (status === "active" && !r.active) return false;
      if (status === "inactive" && r.active) return false;
      if (plan === "subscribed" && !(r.sub_status && r.sub_status !== "expired")) return false;
      if (plan === "none" && r.sub_status && r.sub_status !== "expired") return false;
      if (verified === "verified" && !r.phone_verified) return false;
      if (verified === "unverified" && r.phone_verified) return false;
      if (needle) {
        const hay = [r.name, r.mobile, r.agent_id, r.region, regionOf(r.region), r.plan, r.app_version].join(" ").toLowerCase();
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
  }, [d, q, status, plan, verified, sort, labels]);

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
    const cu = peekCached<Data>("users");
    if (cu) setCached("users", { ...cu, region_labels: next });
    await fetch("/api/config", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key: "region_labels", value: next }) });
  }

  function exportCsv() {
    const head = ["Agent name", "Mobile", "Phone", "Agent ID", "Region", "District", "Accounts", "Monthly book", "Collected", "Plan", "Status", "Phone verified", "Version", "First seen", "Last seen"];
    const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const lines = view.map((r) =>
      [r.name, r.mobile, r.model, r.agent_id, r.region, regionOf(r.region), r.accounts, r.value, r.collected, r.plan, r.active ? "active" : "dormant", r.phone_verified ? "yes" : "no", r.app_version, r.first_seen, r.last_seen].map(esc).join(",")
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
        <div className="grid gap-3.5 grid-cols-2 md:grid-cols-6">
          <Kpi icon="agents" label="Agents" value={num(t.agents)} sub={`${num(t.installs)} installs`} />
          <Kpi icon="verified" label="Verified" value={num(t.verified)} />
          <Kpi icon="active" label="Active" value={num(t.active)} sub="7 days" />
          <Kpi icon="accounts" label="Accounts" value={num(t.accounts)} />
          <Kpi icon="value" label="Monthly book" value={inr(t.value)} focal sub="RD / month" />
          <Kpi icon="collected" label="Collected" value={inr(t.collected)} sub={`${num(t.lists)} lists`} />
        </div>
      )}

      <Card className="mt-3.5">
        <div className="flex flex-wrap items-center gap-2 mb-3">
          <input className="input max-w-xs" placeholder="Search name, mobile, agent, ID, region…" value={q} onChange={(e) => setQ(e.target.value)} />
          <Segmented value={status} onChange={(v) => setStatus(v as any)} options={[["all", "All"], ["active", "Active"], ["inactive", "Inactive"]]} />
          <Segmented value={plan} onChange={(v) => setPlan(v as any)} options={[["all", "Any plan"], ["subscribed", "Subscribed"], ["none", "No plan"]]} />
          <Segmented value={verified} onChange={(v) => setVerified(v as any)} options={[["all", "Any"], ["verified", "Verified"], ["unverified", "Unverified"]]} />
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
                      <tr key={i}><td colSpan={9} className="py-2 px-2"><Skel className="h-6 w-full" /></td></tr>
                    ))
                  : view.map((r) => (
                      <tr key={r.device_id} onClick={() => setOpen(r)} className="border-t border-line hover:bg-focal/20 cursor-pointer">
                        <Cell className="font-semibold">{r.name || <span className="text-faint">—</span>}</Cell>
                        <Cell className="font-mono text-xs">{r.mobile || <span className="text-faint">—</span>}</Cell>
                        <Cell right>{r.devices > 1 ? <Pill tone="a">{r.devices}</Pill> : <span className="text-muted">{r.devices}</span>}</Cell>
                        <Cell className="font-mono text-xs">
                          {r.region ? <>{r.region}{regionOf(r.region) && <span className="text-muted font-sans"> · {regionOf(r.region)}</span>}</> : <span className="text-faint">—</span>}
                        </Cell>
                        <Cell right className="font-semibold">{r.accounts != null ? num(r.accounts) : <span className="text-faint">—</span>}</Cell>
                        <Cell right className="font-semibold">{r.value != null ? inr(r.value) : <span className="text-faint">—</span>}</Cell>
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

      {open && (
        <AgentDrawer
          row={open}
          district={regionOf(open.region)}
          onClose={() => setOpen(null)}
          onChanged={reload}
          onRemoved={() => { setOpen(null); reload(); }}
        />
      )}
    </>
  );
}

// --- Per-agent detail drawer ------------------------------------------------

type Detail = {
  events: { event: string; props: Record<string, unknown>; created_at: string }[];
  stats?: { events: number; lists: number; collected: number; first: string | null; last: string | null };
};

type EditForm = { name: string; mobile: string; agent_id: string; sol_id: string };
const formOf = (r: UserRow): EditForm => ({
  name: r.name ?? "",
  mobile: r.mobile ?? "",
  agent_id: r.agent_id ?? "",
  sol_id: r.region ?? "",
});

function AgentDrawer({ row, district, onClose, onChanged, onRemoved }: {
  row: UserRow;
  district: string | null;
  onClose: () => void;
  onChanged: () => void | Promise<void>;
  onRemoved: () => void;
}) {
  const [det, setDet] = useState<Detail | null>(null);
  // Edits are held locally and shown straight away, so the drawer never argues
  // with itself while the table behind it refetches.
  const [form, setForm] = useState<EditForm>(() => formOf(row));
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [confirmText, setConfirmText] = useState("");
  const [removing, setRemoving] = useState(false);
  const [danger, setDanger] = useState(false);
  // Which grant button is in flight (0 means "End now"), so only that one
  // shows a spinner and the rest can't be double-fired.
  const [granting, setGranting] = useState<number | null>(null);
  const [grantMsg, setGrantMsg] = useState<string | null>(null);

  const clean = formOf(row);
  const dirty = (Object.keys(clean) as (keyof EditForm)[]).some((k) => form[k].trim() !== clean[k]);
  const mobileBad = form.mobile.trim().length > 0 &&
    form.mobile.replace(/\D/g, "").length !== 10;

  useEffect(() => {
    setDet(null);
    setForm(formOf(row));
    setMsg(null);
    setDanger(false);
    setConfirmText("");
    fetch(`/api/user?device=${encodeURIComponent(row.device_ids.join(","))}`).then((r) => r.json()).then(setDet).catch(() => setDet({ events: [] }));
    const onEsc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onEsc);
    return () => window.removeEventListener("keydown", onEsc);
  }, [row.device_id, onClose]);

  async function save() {
    if (mobileBad || !dirty) return;
    setSaving(true);
    setMsg(null);
    try {
      const res = await fetch("/api/users", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          deviceIds: row.device_ids,
          patch: {
            // One name, one column. `devices.name` is gone — see
            // admin/schema_one_name.sql.
            mobile: form.mobile.replace(/\D/g, ""),
            agent_name: form.name.trim(),
            agent_id: form.agent_id.trim(),
            sol_id: form.sol_id.trim(),
          },
        }),
      });
      const j = await res.json();
      if (j.ok) {
        setMsg(`Saved to ${j.updated} phone${j.updated === 1 ? "" : "s"}.`);
        await onChanged();
      } else {
        setMsg(j.error || "Couldn't save.");
      }
    } catch {
      setMsg("Couldn't reach the server.");
    } finally {
      setSaving(false);
    }
  }

  /// `days` of 0 ends access now; negative takes time back.
  async function grant(days: number) {
    if (!row.agent_id) return;
    setGranting(days);
    setGrantMsg(null);
    try {
      const res = await fetch("/api/subscriptions", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(
          days === 0
            ? { agentId: row.agent_id, endNow: true }
            : { agentId: row.agent_id, addDays: days },
        ),
      });
      const j = await res.json();
      if (j.ok) {
        const until = j.periodEnd ? new Date(j.periodEnd) : null;
        setGrantMsg(
          days === 0
            ? "Access ended."
            : `Access now runs to ${until ? until.toLocaleDateString() : "the new date"}.`,
        );
        await onChanged();
      } else {
        setGrantMsg(j.error || "Couldn't change access.");
      }
    } catch {
      setGrantMsg("Couldn't reach the server.");
    } finally {
      setGranting(null);
    }
  }

  async function remove() {
    if (confirmText !== "DELETE") return;
    setRemoving(true);
    try {
      const res = await fetch("/api/users", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ deviceIds: row.device_ids, confirm: "DELETE" }),
      });
      const j = await res.json();
      if (j.ok) onRemoved();
      else { setMsg(j.error || "Couldn't remove."); setRemoving(false); }
    } catch {
      setMsg("Couldn't reach the server.");
      setRemoving(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex justify-end" onClick={onClose}>
      <div className="absolute inset-0 bg-ink/20" />
      <aside className="relative w-full max-w-[440px] bg-canvas h-full overflow-y-auto shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <div className="sticky top-0 bg-sidebar text-white px-5 py-4 flex items-start justify-between">
          <div>
            <div className="font-extrabold text-lg leading-tight">{form.name || "Agent"}</div>
            <div className="text-white/60 text-xs mt-0.5">
              {form.mobile ? `+91 ${form.mobile} · ` : ""}{form.sol_id ? `SOL ${form.sol_id}${district ? ` · ${district}` : ""}` : "region unknown"}
            </div>
          </div>
          <button onClick={onClose} className="text-white/70 hover:text-white text-xl leading-none">✕</button>
        </div>

        <div className="p-5 flex flex-col gap-3.5">
          <div className="grid grid-cols-2 gap-3">
            <MiniStat label="Accounts maintained" value={row.accounts != null ? num(row.accounts) : "—"} />
            <MiniStat label="Monthly book ₹" value={row.value != null ? inr(row.value) : "—"} focal />
            <MiniStat label="Collected (submitted)" value={row.collected ? inr(row.collected) : "—"} />
            <MiniStat label="Plan" value={row.plan || "—"} />
            <MiniStat label="Status" value={row.active ? "active" : "dormant"} />
          </div>

          <div className="card p-4">
            <div className="lbl mb-2.5">Details</div>
            <div className="flex flex-col gap-2.5">
              <Field label="Agent name" value={form.name}
                onChange={(v) => setForm({ ...form, name: v })} placeholder="As it appears on his lists" />
              <Field label="Mobile" value={form.mobile} prefix="+91" inputMode="numeric"
                onChange={(v) => setForm({ ...form, mobile: v.replace(/\D/g, "").slice(0, 10) })}
                placeholder="10 digits"
                error={mobileBad ? "Needs to be 10 digits." : null} />
              <Field label="Agent ID" value={form.agent_id} mono
                onChange={(v) => setForm({ ...form, agent_id: v })} />
              <Field label="Region (SOL)" value={form.sol_id} mono
                onChange={(v) => setForm({ ...form, sol_id: v })} />
            </div>
            <div className="flex items-center gap-2.5 mt-3.5">
              <button className="btn" disabled={!dirty || saving || mobileBad} onClick={save}>
                {saving ? "Saving…" : "Save changes"}
              </button>
              {dirty && !saving && (
                <button className="btn btn-ghost" onClick={() => { setForm(formOf(row)); setMsg(null); }}>
                  Reset
                </button>
              )}
              {msg && <span className="text-[12px] text-muted">{msg}</span>}
            </div>
            <p className="text-[11.5px] text-faint mt-2.5">
              Applies to {row.devices === 1 ? "this phone" : `all ${row.devices} of this agent's phones`}.
              The app overwrites these on its next check-in, so an edit here is a
              correction, not a permanent override.
            </p>
          </div>

          <div className="card p-4 text-[13px]">
            <Row k="Phone verified" v={row.phone_verified ? "yes" : "no"} />
            <Row k="Phone" v={row.model || "—"} />
            <Row k="App version" v={row.app_version || "—"} />
            <Row k="Signed in on" v={`${row.signed_in} phone${row.signed_in === 1 ? "" : "s"}`} />
            {/* This used to say a reinstall or "Clear data" made the same phone
                look new. That stopped being true when the device id started
                being derived from ANDROID_ID so it survives both — see
                DeviceIdentity.id(). The line stayed, describing behaviour that
                no longer existed, which made the number impossible to explain.
                What actually leaves a ghost now is listed below. */}
            <Row
              k="Installs seen"
              v={
                row.devices > row.signed_in
                  ? `${row.devices} — ${row.devices - row.signed_in} with no live session (signed out, replaced, factory reset, or an install from before device ids became durable). Only the signed-in count is charged against his limit.`
                  : String(row.devices)
              }
            />
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

          {/* Access is granted by hand for now — pricing is agreed per agent
              from their book size and usage, so this is the control that
              actually decides whether they can work. */}
          <div className="card p-4">
            <div className="lbl mb-2">Access</div>
            {!row.agent_id ? (
              <p className="text-[12.5px] text-muted">
                No Agent ID yet — access is keyed to it, so there is nothing to
                grant until they finish signing in.
              </p>
            ) : (
              <>
                <div className="flex items-baseline gap-2 mb-1">
                  <span className="text-[15px] font-extrabold">
                    {row.sub_status === "active" ? "Active"
                      : row.sub_status === "trial" ? "On trial"
                      : row.sub_status === "expired" ? "Ended"
                      : "No record yet"}
                  </span>
                  {row.plan && <Pill>{row.plan}</Pill>}
                </div>
                <p className="text-[12px] text-faint mb-3">
                  Adding days stacks on whatever is left, exactly like a real
                  purchase — time already given is never burned.
                </p>
                <div className="flex flex-wrap gap-2">
                  {[7, 30, 90].map((d) => (
                    <button key={d} className="btn btn-ghost"
                      disabled={granting !== null}
                      onClick={() => grant(d)}>
                      {granting === d ? "…" : `+${d} days`}
                    </button>
                  ))}
                  <button className="btn btn-ghost"
                    disabled={granting !== null}
                    onClick={() => grant(-30)}>
                    {granting === -30 ? "…" : "−30 days"}
                  </button>
                  <button className="btn btn-ghost !text-red"
                    disabled={granting !== null}
                    onClick={() => grant(0)}>
                    {granting === 0 ? "…" : "End now"}
                  </button>
                </div>
                {grantMsg && (
                  <p className="text-[12px] text-muted mt-2.5">{grantMsg}</p>
                )}
              </>
            )}
          </div>

          {/* Removal sits last, behind its own disclosure and a typed
              confirmation. It cannot be reached by a mis-tap on the way to
              anything else. */}
          <div className="card p-4">
            {!danger ? (
              <button className="text-[12.5px] font-bold text-red hover:underline"
                onClick={() => setDanger(true)}>
                Remove this agent…
              </button>
            ) : (
              <div className="flex flex-col gap-2.5">
                <div className="lbl">Remove agent</div>
                <p className="text-[12.5px] text-muted leading-relaxed">
                  Deletes {row.devices === 1 ? "this install" : `all ${row.devices} installs`},
                  their activity history, and their sign-in sessions — the agent
                  is signed out everywhere and their phone number and Agent ID
                  are freed for reuse.
                </p>
                <p className="text-[12.5px] text-muted leading-relaxed">
                  <b>Payments and subscriptions are kept.</b> Those are accounting
                  records; if this agent signs up again their entitlement is
                  still theirs.
                </p>
                <p className="text-[12.5px] text-muted">
                  Their own customer data was never on our servers, so it is
                  untouched — it lives only on their phone.
                </p>
                <input
                  className="input"
                  value={confirmText}
                  onChange={(e) => setConfirmText(e.target.value)}
                  placeholder="Type DELETE to confirm"
                  aria-label="Type DELETE to confirm"
                />
                <div className="flex items-center gap-2.5">
                  <button
                    className="btn !bg-red disabled:!bg-line disabled:!text-faint"
                    disabled={confirmText !== "DELETE" || removing}
                    onClick={remove}
                  >
                    {removing ? "Removing…" : "Remove permanently"}
                  </button>
                  <button className="btn btn-ghost"
                    onClick={() => { setDanger(false); setConfirmText(""); }}>
                    Cancel
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      </aside>
    </div>
  );
}

/** One labelled input in the drawer's edit card. */
function Field({ label, value, onChange, placeholder, mono, prefix, inputMode, error }: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  mono?: boolean;
  prefix?: string;
  inputMode?: "numeric" | "text";
  error?: string | null;
}) {
  return (
    <label className="block">
      <span className="lbl">{label}</span>
      <span className="flex items-center gap-2 mt-1">
        {prefix && <span className="text-[13px] text-muted font-bold">{prefix}</span>}
        <input
          className={`input ${mono ? "font-mono" : ""} ${error ? "!border-red" : ""}`}
          value={value}
          inputMode={inputMode}
          placeholder={placeholder}
          onChange={(e) => onChange(e.target.value)}
        />
      </span>
      {error && <span className="text-[11.5px] text-red mt-1 block">{error}</span>}
    </label>
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
