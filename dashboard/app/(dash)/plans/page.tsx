"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel, Table, Td, Th } from "@/components/ui";
import { inr, num } from "@/lib/format";
import { hasAccess, isFreeAccess, isPaying, paidPlanCodes, planLabel } from "@/lib/subs";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";

type Plan = {
  code: string;
  name: string;
  price_inr: number;
  duration_days: number;
  active: boolean;
  sort: number;
};
type Sub = {
  agent_id: string;
  plan_code: string;
  plan_name: string;
  agent_name: string | null;
  status: string;
  /** Null for a derived trial — no stored period to count down from. */
  days_left: number | null;
  /** True when a real subscriptions row backs this, not a derived trial. */
  has_row: boolean;
  current_period_end: string;
};
type Data = {
  plans: Plan[];
  config: { payments_enabled: boolean; trial_days: number };
  subscribers: Sub[];
  mrr: { day: string; revenue: number; payments: number }[];
};

function Toggle({ on, onChange, tone = "green" }: { on: boolean; onChange: (v: boolean) => void; tone?: "green" | "red" }) {
  return (
    <button
      onClick={() => onChange(!on)}
      className={`w-12 h-7 rounded-full transition relative shrink-0 ${on ? (tone === "red" ? "bg-red" : "bg-green") : "bg-line"}`}
    >
      <span className={`absolute top-1 w-5 h-5 rounded-full bg-white shadow transition-all ${on ? "left-6" : "left-1"}`} />
    </button>
  );
}

const empty: Plan = { code: "", name: "", price_inr: 0, duration_days: 30, active: true, sort: 99 };

export default function Plans() {
  /// Which slice of the roster to show. Defaults to everyone — the table used to
  /// be a roster of one because it only listed real subscription rows.
  const [subFilter, setSubFilter] =
      useState<"all" | "paying" | "trial" | "expired">("all");
  const [data, setData] = useState<Data | null>(() => peekCached<Data>("plans"));
  const [rows, setRows] = useState<Plan[]>(() => peekCached<Data>("plans")?.plans || []);
  const [adding, setAdding] = useState<Plan | null>(null);
  const [busy, setBusy] = useState("");
  const [flash, setFlash] = useState("");
  // Repairing an agent who has NO subscriber row yet — the stranded-first-purchase
  // case, where there is no row to click.
  const [repair, setRepair] = useState({ agentId: "", days: 30 });

  // `fresh` bypasses the API's 30s cache — pass it after a write, so the KPI
  // cards reflect the change that just landed instead of the payload from
  // before it. `no-store` keeps the browser from answering from its own cache.
  async function load(fresh = false) {
    const d = (await fetch(fresh ? "/api/plans?fresh=1" : "/api/plans", {
      cache: "no-store",
    }).then((r) => r.json())) as Data;
    setCached("plans", d);
    setData(d);
    setRows(d.plans || []);
    // The trial row's Days is the single control; keep the value `pay` reads
    // (app_config.trial_days) in lockstep with it. If they ever drift, reconcile
    // app_config to the trial row.
    const trial = (d.plans || []).find((p) => p.code === "trial");
    if (trial && Number(trial.duration_days) !== Number(d.config?.trial_days)) {
      const days = Number(trial.duration_days) || 0;
      setData((prev) => (prev ? { ...prev, config: { ...prev.config, trial_days: days } } : prev));
      fetch("/api/plans", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ key: "trial_days", value: days }),
      });
    }
  }
  useEffect(() => {
    if (!isFresh("plans")) load();
  }, []);

  function say(m: string) {
    setFlash(m);
    setTimeout(() => setFlash(""), 1600);
  }

  async function setConfig(key: "payments_enabled" | "trial_days", value: unknown) {
    setData((d) => (d ? { ...d, config: { ...d.config, [key]: value } } : d));
    await fetch("/api/plans", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, value }),
    });
    say("Saved.");
  }

  async function savePlan(p: Plan) {
    setBusy(p.code);
    const res = await fetch("/api/plans", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(p),
    }).then((r) => r.json());
    // The `pay` edge function grants the trial from app_config.trial_days, so a
    // trial-row Days edit must also write that value — otherwise it would look
    // saved but do nothing (the bug we're fixing). The trial row is the single
    // control; app_config.trial_days just mirrors it for `pay`.
    if (!res.error && p.code === "trial") {
      const days = Math.max(0, Math.floor(Number(p.duration_days) || 0));
      await fetch("/api/plans", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ key: "trial_days", value: days }),
      });
      setData((d) => (d ? { ...d, config: { ...d.config, trial_days: days } } : d));
    }
    setBusy("");
    if (res.error) say(res.error);
    else say(`Saved “${p.name}”.`);
  }

  async function toggleActive(p: Plan, active: boolean) {
    setRows((rs) => rs.map((r) => (r.code === p.code ? { ...r, active } : r)));
    await fetch("/api/plans", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: p.code, active }),
    });
    say(active ? `“${p.name}” is now offered to users.` : `“${p.name}” hidden from users.`);
  }

  async function addPlan() {
    if (!adding) return;
    const res = await fetch("/api/plans", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(adding),
    }).then((r) => r.json());
    if (res.error) return say(res.error);
    setAdding(null);
    await load(true);
    say("Plan added.");
  }

  // Repair one agent's access by hand. The one activation failure that cannot
  // self-heal is "payment recorded, subscription not extended" — the payment id
  // is already on file, so a replay reads it as settled and skips the extension.
  // The edge functions log the agent id and plan for exactly this moment.
  async function adjust(agentId: string, body: Record<string, unknown>, label: string) {
    if (!agentId.trim()) return say("Agent ID is required.");
    setBusy(`sub:${agentId}`);
    const res = await fetch("/api/subscriptions", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ agentId: agentId.trim(), ...body }),
    }).then((r) => r.json());
    setBusy("");
    if (res.error) return say(res.error);
    await load(true);
    say(`${agentId.trim()}: ${label}.`);
  }

  async function del(code: string) {
    const res = await fetch("/api/plans", {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    }).then((r) => r.json());
    if (res.error) return say(res.error);
    await load(true);
    say("Plan deleted.");
  }

  function edit(code: string, patch: Partial<Plan>) {
    setRows((rs) => rs.map((r) => (r.code === code ? { ...r, ...patch } : r)));
  }

  if (!data) {
    return (
      <>
        <PageHead title="Plans & Subscriptions" subtitle="Edit pricing and roll plans out to every install — no app update needed" />
        <Card><Skel className="h-16 w-full" /></Card>
        <div className="mt-4"><KpiSkeletons n={4} grid="grid-cols-2 md:grid-cols-4" focal /></div>
        <Card title="Plans" className="mt-4"><Skel className="h-40 w-full" /></Card>
      </>
    );
  }

  const on = data.config.payments_enabled !== false;
  // This tab happened to be right while the others were wrong, but only because
  // /api/plans coerces a null plan_code to "trial" on the way out. Use the same
  // price rule as everywhere else so it is right on purpose — see lib/subs.ts.
  const paidCodes = paidPlanCodes(rows);
  const shown = data.subscribers.filter((s) =>
    subFilter === "all"
      ? true
      : subFilter === "paying"
        ? isPaying(s, paidCodes)
        : subFilter === "trial"
          ? isFreeAccess(s, paidCodes)
          : !hasAccess(s));
  // Anyone whose access has not lapsed — PAID AND FREE together. The name
  // matters because `status` reads 'active' on a free trial too, so a tile
  // called "Active subscribers" that includes trialists reads as a
  // contradiction of the data. Labelled "With access" below instead.
  const withAccess = data.subscribers.filter(hasAccess);
  const paidSubs = withAccess.filter((s) => isPaying(s, paidCodes));
  // v_mrr is every successful Razorpay payment grouped by day, with no date
  // window — so summing it is revenue ALL TIME, not a monthly recurring figure,
  // whatever the view is called.
  const revenueAllTime = (data.mrr || []).reduce((a, b) => a + Number(b.revenue || 0), 0);

  return (
    <>
      <PageHead
        title="Plans & Subscriptions"
        subtitle="Edit pricing and roll plans out to every install — no app update needed"
        right={<span className="text-muted text-xs">{flash}</span>}
      />

      {/* Master rollout switch */}
      <Card tone={on ? "g" : undefined}>
        <div className="flex items-center justify-between gap-4">
          <div>
            <div className="font-semibold text-lead">
              Paywall {on ? "is LIVE" : "is OFF"}
            </div>
            <div className="text-muted text-body mt-0.5 max-w-xl">
              {on
                ? "Agents whose subscription has expired are gated to the paywall. Turning this off instantly gives every install full access."
                : "Master switch is off — every install has full access regardless of plan. Turn on only once Razorpay + the native checkout ship in a release build."}
            </div>
          </div>
          <Toggle on={on} tone={on ? "green" : "red"} onChange={(v) => setConfig("payments_enabled", v)} />
        </div>
      </Card>

      <div className="grid gap-4 grid-cols-2 md:grid-cols-4 mt-4 stagger">
        <Kpi label="Paying" value={num(paidSubs.length)} sub="excl. trials" focal />
        <Kpi label="With access" value={num(withAccess.length)} sub="incl. trials" />
        <Kpi label="Plans offered" value={num(rows.filter((r) => r.active).length)} sub={`${num(rows.length)} total`} />
        <Kpi label="Revenue" value={inr(revenueAllTime)} sub="all time" href="/payments" />
      </div>

      {/* Plan editor */}
      <Card title="Plans" className="mt-4" right={
        <button className="btn btn-ghost" onClick={() => setAdding({ ...empty })}>+ Add plan</button>
      }>
        <Table>
          <thead>
            <tr>
              <Th>Code</Th><Th>Name</Th><Th>Price (₹)</Th><Th>Days</Th>
              <Th>Sort</Th><Th>Offered</Th><Th></Th>
            </tr>
          </thead>
          <tbody>
            {/* Important, so the shared .tbl row hover doesn't wash the
                half-typed plan back to the ordinary row colour. */}
            {adding && (
              <tr className="!bg-focal/30">
                <Td><input className="input py-1.5 w-24" placeholder="code" value={adding.code} onChange={(e) => setAdding({ ...adding, code: e.target.value })} /></Td>
                <Td><input className="input py-1.5 w-32" placeholder="name" value={adding.name} onChange={(e) => setAdding({ ...adding, name: e.target.value })} /></Td>
                <Td><input type="number" className="input py-1.5 w-24" value={adding.price_inr} onChange={(e) => setAdding({ ...adding, price_inr: Number(e.target.value) })} /></Td>
                <Td><input type="number" className="input py-1.5 w-20" value={adding.duration_days} onChange={(e) => setAdding({ ...adding, duration_days: Number(e.target.value) })} /></Td>
                <Td><input type="number" className="input py-1.5 w-16" value={adding.sort} onChange={(e) => setAdding({ ...adding, sort: Number(e.target.value) })} /></Td>
                <Td className="text-muted text-xs">—</Td>
                <Td>
                  <div className="flex gap-1.5">
                    <button className="btn py-1.5 px-3" onClick={addPlan}>Add</button>
                    <button className="btn btn-ghost py-1.5 px-3" onClick={() => setAdding(null)}>✕</button>
                  </div>
                </Td>
              </tr>
            )}
            {rows.map((p) => (
              <tr key={p.code} className={p.active ? "" : "opacity-55"}>
                <Td className="font-mono text-xs">{p.code}</Td>
                <Td><input className="input py-1.5 w-32" value={p.name} onChange={(e) => edit(p.code, { name: e.target.value })} /></Td>
                <Td><input type="number" className="input py-1.5 w-24" value={p.price_inr} onChange={(e) => edit(p.code, { price_inr: Number(e.target.value) })} /></Td>
                <Td>
                  <input
                    type="number"
                    className="input py-1.5 w-20"
                    value={p.duration_days}
                    onChange={(e) => edit(p.code, { duration_days: Number(e.target.value) })}
                    title={p.code === "trial" ? "Free-trial length granted to every new agent" : undefined}
                  />
                </Td>
                <Td><input type="number" className="input py-1.5 w-16" value={p.sort} onChange={(e) => edit(p.code, { sort: Number(e.target.value) })} /></Td>
                <Td><Toggle on={p.active} onChange={(v) => toggleActive(p, v)} /></Td>
                <Td>
                  <div className="flex gap-1.5">
                    <button className="btn py-1.5 px-3" disabled={busy === p.code} onClick={() => savePlan(p)}>
                      {busy === p.code ? "…" : "Save"}
                    </button>
                    {p.code !== "trial" && (
                      <button className="btn btn-ghost py-1.5 px-3" title="Delete" onClick={() => del(p.code)}>🗑</button>
                    )}
                  </div>
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!rows.length && !adding && (
          <Empty action="Press “+ Add plan” above, or run admin/schema_payments.sql to seed the standard tiers.">
            No plans defined
          </Empty>
        )}
        <p className="text-muted text-xs mt-3">
          The app reads this list live — flipping <b>Offered</b> off hides a tier from every install on their next
          refresh. The <b>trial</b> row’s <b>Days</b> is the free-trial length granted to every new agent (edit it here,
          then Save). Deleting a plan with existing subscribers is blocked; deactivate it instead.
        </p>
      </Card>

      {/* Subscribers — REAL rows only.
          While payments_enabled is off, `pay` hands the app a trial without
          writing a row, so most agents on a trial do not appear here at all.
          That is the table being honest about what exists, not a bug — but it
          means this is not a roster of who is using the app. The Users tab is. */}
      <Card title="Subscribers" className="mt-4"
            right={
              <div className="flex items-center gap-2">
                {(["all", "paying", "trial", "expired"] as const).map((f) => (
                  <button key={f}
                    className={`btn ${subFilter === f ? "" : "btn-ghost"} py-1 px-2 text-xs`}
                    onClick={() => setSubFilter(f)}>
                    {f}
                  </button>
                ))}
                <span className="text-muted text-xs">
                  {shown.length > 100 ? `100 of ${shown.length}` : `${shown.length}`}
                </span>
              </div>
            }>
        <Table>
          <thead>
            <tr><Th>Agent</Th><Th>Plan</Th><Th>Status</Th><Th num>Days left</Th><Th>Renews / ended</Th><Th>Fix access</Th></tr>
          </thead>
          <tbody>
            {shown.slice(0, 100).map((s) => (
              <tr key={s.agent_id}>
                <Td>
                  <div className="font-semibold">{s.agent_name || "—"}</div>
                  <div className="font-mono text-micro text-muted">{s.agent_id}</div>
                </Td>
                <Td>{planLabel(s, rows)}</Td>
                <Td>
                  <Pill tone={s.status === "active" ? "g" : s.status === "trial" ? "b" : "r"}>{s.status}</Pill>
                </Td>
                <Td num className="font-semibold">{s.days_left == null ? <span className="text-muted font-normal">—</span> : num(s.days_left)}</Td>
                <Td className="text-muted text-xs">
                  {s.current_period_end ? new Date(s.current_period_end).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "2-digit" }) : "—"}
                </Td>
                <Td>
                  <div className="flex gap-1.5">
                    {[7, 30].map((d) => (
                      <button
                        key={d}
                        className="btn btn-ghost py-1 px-2 text-xs"
                        title={`Grant ${d} more days — stacks onto any time left`}
                        disabled={busy === `sub:${s.agent_id}`}
                        onClick={() => adjust(s.agent_id, { addDays: d }, `+${d} days`)}
                      >
                        +{d}d
                      </button>
                    ))}
                    <button
                      className="btn btn-ghost py-1 px-2 text-xs"
                      title="End access now — use after a full refund"
                      disabled={busy === `sub:${s.agent_id}`}
                      onClick={() => {
                        if (confirm(`End access for ${s.agent_id} right now?`))
                          adjust(s.agent_id, { endNow: true }, "access ended");
                      }}
                    >
                      End
                    </button>
                  </div>
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!data.subscribers.length && (
          <Empty action="While payments are off a trial is handed out without writing a row — switch payments on above, or repair a stranded payment below.">
            No subscription rows exist
          </Empty>
        )}

        {/* The stranded-payment repair. An agent who paid but never got a
            subscription row won't appear in the table above, so they need a
            place to be typed in. */}
        <div className="mt-4 pt-4 border-t border-line">
          <div className="flex flex-wrap items-center gap-2">
            <input
              className="input font-mono text-xs w-52"
              placeholder="Agent ID"
              value={repair.agentId}
              onChange={(e) => setRepair({ ...repair, agentId: e.target.value })}
            />
            <input
              className="input w-20"
              type="number"
              value={repair.days}
              onChange={(e) => setRepair({ ...repair, days: Number(e.target.value) })}
            />
            <span className="text-muted text-xs">days</span>
            <button
              className="btn py-1.5 px-3"
              disabled={busy === `sub:${repair.agentId.trim()}`}
              onClick={() =>
                adjust(repair.agentId, { addDays: repair.days }, `+${repair.days} days`)
                  .then(() => setRepair({ agentId: "", days: 30 }))
              }
            >
              Grant
            </button>
          </div>
          <p className="text-muted text-xs mt-2">
            For a payment that went through but didn’t activate. The edge-function logs name it:
            look for <b>subscription not extended</b> (or <b>activate_failed</b> / <b>stranded</b>) — the
            agent ID and plan are logged alongside. Granted days stack onto any time left, exactly like a
            real purchase, and every adjustment is recorded as a <b>manual</b> row in Transactions
            (kept out of revenue).
          </p>
        </div>
      </Card>
    </>
  );
}
