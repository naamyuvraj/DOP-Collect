"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel, Td, Th } from "@/components/ui";
import { inr, num } from "@/lib/format";

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
  status: string;
  days_left: number;
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
  const [data, setData] = useState<Data | null>(null);
  const [rows, setRows] = useState<Plan[]>([]);
  const [adding, setAdding] = useState<Plan | null>(null);
  const [busy, setBusy] = useState("");
  const [flash, setFlash] = useState("");

  async function load() {
    const d = (await fetch("/api/plans").then((r) => r.json())) as Data;
    setData(d);
    setRows(d.plans || []);
    // Self-heal any past drift: the trial plan's Days must equal trial_days (the
    // value `pay` actually uses). If they diverged, reconcile the plan row.
    const trial = (d.plans || []).find((p) => p.code === "trial");
    if (trial && Number(trial.duration_days) !== Number(d.config?.trial_days)) {
      const days = Number(d.config?.trial_days) || 0;
      setRows((rs) => rs.map((r) => (r.code === "trial" ? { ...r, duration_days: days } : r)));
      fetch("/api/plans", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: "trial", duration_days: days }),
      });
    }
  }
  useEffect(() => {
    load();
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

  // The trial length is app_config.trial_days — the ONLY value the `pay` edge
  // function uses to grant a trial. We also mirror it onto the `trial` plan row's
  // duration_days so the plan list the app shows stays consistent (they used to
  // drift, which is why editing the row's Days appeared to do nothing).
  async function setTrialDays(v: number) {
    const days = Math.max(0, Math.floor(Number(v) || 0));
    setData((d) => (d ? { ...d, config: { ...d.config, trial_days: days } } : d));
    setRows((rs) => rs.map((r) => (r.code === "trial" ? { ...r, duration_days: days } : r)));
    await fetch("/api/plans", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: "trial_days", value: days }),
    });
    // Keep the trial plan row in sync (no-op if there's no trial plan row).
    if (rows.some((r) => r.code === "trial")) {
      await fetch("/api/plans", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: "trial", duration_days: days }),
      });
    }
    say("Trial length saved.");
  }

  async function savePlan(p: Plan) {
    setBusy(p.code);
    // For the trial, Days is governed by trial_days — never write a stale value.
    const payload = p.code === "trial" ? { ...p, duration_days: data?.config.trial_days ?? p.duration_days } : p;
    const res = await fetch("/api/plans", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    }).then((r) => r.json());
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
    await load();
    say("Plan added.");
  }

  async function del(code: string) {
    const res = await fetch("/api/plans", {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    }).then((r) => r.json());
    if (res.error) return say(res.error);
    await load();
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
        <div className="mt-3.5"><KpiSkeletons n={4} /></div>
        <Card title="Plans" className="mt-3.5"><Skel className="h-40 w-full" /></Card>
      </>
    );
  }

  const on = data.config.payments_enabled !== false;
  const activeSubs = data.subscribers.filter((s) => s.status !== "expired");
  const mrrRevenue = (data.mrr || []).reduce((a, b) => a + Number(b.revenue || 0), 0);

  return (
    <>
      <PageHead
        title="Plans & Subscriptions"
        subtitle="Edit pricing and roll plans out to every install — no app update needed"
        right={<span className="text-muted text-xs">{flash}</span>}
      />

      {/* Master rollout switch */}
      <Card className={on ? "!bg-greenSoft" : ""}>
        <div className="flex items-center justify-between gap-4">
          <div>
            <div className="font-extrabold text-[15px]">
              Paywall {on ? "is LIVE" : "is OFF"}
            </div>
            <div className="text-muted text-[13px] mt-0.5 max-w-xl">
              {on
                ? "Agents whose subscription has expired are gated to the paywall. Turning this off instantly gives every install full access."
                : "Master switch is off — every install has full access regardless of plan. Turn on only once Razorpay + the native checkout ship in a release build."}
            </div>
          </div>
          <Toggle on={on} tone={on ? "green" : "red"} onChange={(v) => setConfig("payments_enabled", v)} />
        </div>
        <div className="flex items-center gap-3 mt-4 pt-4 border-t border-line">
          <div className="mr-auto">
            <div className="text-sm font-semibold">Free-trial length</div>
            <div className="text-muted text-xs">Days auto-granted to every new agent. This is the only trial control.</div>
          </div>
          <input
            type="number"
            min={0}
            className="input w-24"
            value={data.config.trial_days ?? 14}
            onChange={(e) => setData({ ...data, config: { ...data.config, trial_days: Number(e.target.value) } })}
            onBlur={(e) => setTrialDays(Number(e.target.value))}
          />
          <span className="text-muted text-sm">days</span>
        </div>
      </Card>

      <div className="grid gap-3.5 grid-cols-2 md:grid-cols-4 mt-3.5">
        <Kpi label="Plans offered" value={num(rows.filter((r) => r.active).length)} sub={`${num(rows.length)} total`} />
        <Kpi label="Active subscribers" value={num(activeSubs.length)} focal />
        <Kpi label="Paid subscribers" value={num(activeSubs.filter((s) => s.plan_code !== "trial").length)} />
        <Kpi label="Revenue" value={inr(mrrRevenue)} />
      </div>

      {/* Plan editor */}
      <Card title="Plans" className="mt-3.5" right={
        <button className="btn btn-ghost" onClick={() => setAdding({ ...empty })}>+ Add plan</button>
      }>
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>Code</Th><Th>Name</Th><Th>Price (₹)</Th><Th>Days</Th>
                <Th>Sort</Th><Th>Offered</Th><Th></Th>
              </tr>
            </thead>
            <tbody>
              {adding && (
                <tr className="bg-focal/30">
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
                    {p.code === "trial" ? (
                      <span
                        className="text-muted text-xs whitespace-nowrap"
                        title="Trial length is set by ‘Free-trial length’ above"
                      >
                        {num(data.config.trial_days)} · set above
                      </span>
                    ) : (
                      <input type="number" className="input py-1.5 w-20" value={p.duration_days} onChange={(e) => edit(p.code, { duration_days: Number(e.target.value) })} />
                    )}
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
              {!rows.length && !adding && (
                <tr><Td className="text-muted">No plans yet — add one, or run admin/schema_payments.sql.</Td></tr>
              )}
            </tbody>
          </table>
        </div>
        <p className="text-muted text-xs mt-3">
          The app reads this list live — flipping <b>Offered</b> off hides a tier from every install on their next
          refresh. Deleting a plan with existing subscribers is blocked; deactivate it instead.
        </p>
      </Card>

      {/* Subscribers */}
      <Card title="Subscribers" className="mt-3.5">
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr><Th>Agent</Th><Th>Plan</Th><Th>Status</Th><Th>Days left</Th><Th>Renews / ended</Th></tr>
            </thead>
            <tbody>
              {data.subscribers.slice(0, 100).map((s) => (
                <tr key={s.agent_id}>
                  <Td className="font-mono text-xs">{s.agent_id}</Td>
                  <Td>{s.plan_name || s.plan_code}</Td>
                  <Td>
                    <Pill tone={s.status === "active" ? "g" : s.status === "trial" ? "b" : "r"}>{s.status}</Pill>
                  </Td>
                  <Td>{num(s.days_left)}</Td>
                  <Td className="text-muted text-xs">
                    {s.current_period_end ? new Date(s.current_period_end).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "2-digit" }) : "—"}
                  </Td>
                </tr>
              ))}
            </tbody>
          </table>
          {!data.subscribers.length && <Empty>No subscribers yet.</Empty>}
        </div>
      </Card>
    </>
  );
}
