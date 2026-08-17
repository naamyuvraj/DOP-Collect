"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { TrendArea } from "@/components/LazyCharts";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Table, Td, Th } from "@/components/ui";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";
import { day, num, when } from "@/lib/format";

type Win = { sent: number; failed: number; blocked: number; verified: number };
type Day = {
  day: string; sent: number; failed: number; blocked: number;
  verified: number; verify_failed: number;
};
type Payload = {
  daily: Day[];
  failures: { action: string; status: string; n: number; last_seen: string }[];
  top: { phone_hash: string; sent: number; verified: number; blocked: number; last_seen: string }[];
  verifiedAccounts?: number;
  balance?: Record<string, string> | null;
  cost: { currency: string; perMessage: number; monthlyBudget: number };
  config: Record<string, any>;
  windows?: { d1: Win; d7: Win; d30: Win; all: Win };
  mtdSent?: number;
  error?: string;
};

const ZERO: Win = { sent: 0, failed: 0, blocked: 0, verified: 0 };

/** Rupees with paise — spend here is often a few tens of rupees, so ₹0 lies. */
const money = (n: number) =>
  "₹" + (Math.round(n * 100) / 100).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** Plain-English name for a status the edge function logs. */
const STATUS_LABEL: Record<string, string> = {
  provider_error: "MSG91 rejected the send",
  cooldown: "Too soon after the last code",
  rate_limited: "Hourly cap hit (phone / IP / device)",
  not_configured: "MSG91 secrets missing",
  invalid: "Wrong code entered",
  expired: "Code expired or none pending",
  too_many_attempts: "Burned after too many wrong tries",
  reauth_required: "Phone change without a live session",
  account_disabled: "Account disabled",
};
/** Statuses that cost money vs. ones that saved it. */
const COSTLY = new Set(["provider_error"]);
const SAVED = new Set(["cooldown", "rate_limited"]);

function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      onClick={() => onChange(!on)}
      className={`w-12 h-7 rounded-full transition relative shrink-0 ${on ? "bg-green" : "bg-line"}`}
    >
      <span className={`absolute top-1 w-5 h-5 rounded-full bg-white shadow transition-all ${on ? "left-6" : "left-1"}`} />
    </button>
  );
}

function NumField({
  label, help, value, step = 1, onChange,
}: {
  label: string; help?: string; value: number; step?: number;
  onChange: (v: number) => void;
}) {
  return (
    <label className="block">
      <span className="lbl">{label}</span>
      <input
        type="number"
        step={step}
        min={0}
        className="input mt-1"
        value={Number.isFinite(value) ? value : 0}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      {help && <span className="block text-muted text-[11px] mt-1">{help}</span>}
    </label>
  );
}

export default function Otp() {
  const [d, setD] = useState<Payload | null>(() => peekCached<Payload>("otp"));
  const [cost, setCost] = useState({ perMessage: 0.85, monthlyBudget: 0 });
  const [limits, setLimits] = useState<Record<string, number>>({});
  const [saved, setSaved] = useState("");

  function seed(p: Payload) {
    setCost({
      perMessage: Number(p.cost?.perMessage ?? 0.85),
      monthlyBudget: Number(p.cost?.monthlyBudget ?? 0),
    });
    // Defaults mirror the fallbacks in supabase/functions/otp/index.ts, so a
    // key the config row never had still shows the number actually in force.
    const L = p.config?.otp_limits || {};
    setLimits({
      cooldown: L.cooldown ?? 30,
      maxSendPerHour: L.maxSendPerHour ?? 5,
      maxIpPerHour: L.maxIpPerHour ?? 30,
      maxDevicePerHour: L.maxDevicePerHour ?? 10,
      ttl: L.ttl ?? 600,
      maxAttempts: L.maxAttempts ?? 5,
    });
  }

  async function load() {
    const r: Payload = await fetch("/api/otp").then((r) => r.json());
    setCached("otp", r);
    setD(r);
    seed(r);
  }
  useEffect(() => {
    const c = peekCached<Payload>("otp");
    if (c) seed(c);
    if (!isFresh("otp")) load();
  }, []);

  async function save(key: string, value: any, note: string) {
    await fetch("/api/otp", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key, value }),
    });
    setSaved(note);
    setTimeout(() => setSaved(""), 2000);
    load();
  }

  if (!d) {
    return (
      <>
        <PageHead title="OTP & MSG91" subtitle="Loading verification volume and spend…" />
        <KpiSkeletons n={4} grid="grid-cols-2 md:grid-cols-5" focal />
      </>
    );
  }

  const w = d.windows || { d1: ZERO, d7: ZERO, d30: ZERO, all: ZERO };
  const rate = cost.perMessage;
  const spend30 = w.d30.sent * rate;
  const spendAll = w.all.sent * rate;
  const savedRupees = w.d30.blocked * rate;
  const accounts = d.verifiedAccounts ?? 0;
  const perAgent = accounts ? spendAll / accounts : 0;
  const mtd = (d.mtdSent ?? 0) * rate;
  const budget = cost.monthlyBudget;
  const budgetPct = budget > 0 ? Math.min(100, (mtd / budget) * 100) : 0;
  const otpOn = d.config?.otp_required === true;

  // Sends that never became a verify: the wasted half of the bill.
  const wasted = Math.max(0, w.all.sent - w.all.verified);

  const chart = d.daily.slice(-30).map((r) => ({
    ...r,
    label: day(r.day),
    spend: Math.round(Number(r.sent) * rate * 100) / 100,
  }));

  return (
    <>
      <PageHead
        title="OTP & MSG91"
        subtitle="WhatsApp verification volume, what it costs, and the limits that cap it"
        right={
          <div className="flex items-center gap-2">
            <Pill tone={otpOn ? "g" : "a"}>{otpOn ? "Verification ON" : "Verification OFF"}</Pill>
            <button className="btn" onClick={load}>Refresh</button>
          </div>
        }
      />

      {d.error && (
        <div className="card p-3 mb-3.5 text-red text-xs font-semibold">
          Couldn’t read some data: {d.error}
        </div>
      )}

      <div className="grid gap-3.5 grid-cols-2 md:grid-cols-5">
        <Kpi
          label="Messages sent · 30d"
          value={num(w.d30.sent)}
          sub={`${num(w.all.sent)} all time · ${num(w.d1.sent)} today`}
          icon="ai"
          focal
        />
        <Kpi
          label="Estimated spend · 30d"
          value={money(spend30)}
          sub={`at ${money(rate)}/message — estimate`}
          icon="revenue"
        />
        <Kpi
          label="Blocked by limits · 30d"
          value={num(w.d30.blocked)}
          sub={savedRupees > 0 ? `≈ ${money(savedRupees)} not spent` : "no sends refused"}
          icon="keys"
        />
        <Kpi
          label="Cost per verified agent"
          value={accounts ? money(perAgent) : "—"}
          sub={accounts ? `${money(spendAll)} ÷ ${num(accounts)} accounts` : "no verified accounts yet"}
          icon="verified"
        />
      </div>

      <p className="text-muted text-[11px] mt-2">
        Spend is <strong>estimated</strong>: we count messages MSG91 accepted, then multiply by the rate
        you set below. MSG91 never tells us the real per-message price — check the wallet for what you owe.
      </p>

      <div className="grid gap-3.5 lg:grid-cols-[1.4fr_1fr] mt-3.5">
        <Card title="Messages sent per day" right={<span className="text-muted text-[11px]">last 30 days</span>}>
          {chart.some((c) => c.sent > 0) ? (
            <TrendArea data={chart} x="label" y="sent" height={220} />
          ) : (
            <Empty action="Nothing has been billed. Turn on “Require phone verification” below to start sending.">
              No OTPs sent in the last 30 days
            </Empty>
          )}
        </Card>

        <div className="grid gap-3.5 content-start">
          <Card title="This month">
            <div className="flex items-end justify-between">
              <div>
                <div className="text-[26px] font-extrabold leading-none tracking-tight">{money(mtd)}</div>
                <div className="text-muted text-[12px] font-semibold mt-1.5">
                  {num(d.mtdSent ?? 0)} messages since the 1st
                </div>
              </div>
              {budget > 0 && (
                <div className="text-right">
                  <div className="lbl">of {money(budget)}</div>
                  <div className={`font-extrabold ${budgetPct > 90 ? "text-red" : "text-green"}`}>
                    {Math.round(budgetPct)}%
                  </div>
                </div>
              )}
            </div>
            {budget > 0 && (
              <div className="h-2 rounded-full bg-line mt-3 overflow-hidden">
                <div
                  className={`h-full rounded-full ${budgetPct > 90 ? "bg-red" : "bg-green"}`}
                  style={{ width: `${budgetPct}%` }}
                />
              </div>
            )}
          </Card>

          <Card title="MSG91 wallet">
            {d.balance ? (
              <>
                <div className="grid grid-cols-2 gap-2">
                  {Object.entries(d.balance).map(([k, v]) => (
                    <div key={k} className="rounded-xl bg-canvas p-3">
                      <div className="lbl">{k}</div>
                      <div className="font-extrabold text-lg mt-1">{v}</div>
                    </div>
                  ))}
                </div>
                <p className="text-muted text-[11px] mt-2.5">
                  Live from MSG91. This is the authoritative balance; everything else on this page is our own count.
                </p>
              </>
            ) : (
              <p className="text-muted text-xs">
                Not connected. Add <code className="font-mono">MSG91_AUTHKEY</code> to the dashboard’s
                environment (the same key the <code className="font-mono">otp</code> edge function uses) to
                show your live MSG91 balance here. Every other number on this page works without it.
              </p>
            )}
          </Card>
        </div>
      </div>

      {/* items-start so a short card doesn't stretch to match a tall neighbour */}
      <div className="grid gap-3.5 lg:grid-cols-2 items-start mt-3.5">
        <Card title="Where the money goes">
          <Table>
            <tbody>
              {[
                ["Sent (billable)", num(w.all.sent), money(spendAll), "b"],
                ["→ led to a verified sign-in", num(w.all.verified), "", "g"],
                ["→ sent but never verified", num(wasted), money(wasted * rate), "a"],
                ["Failed at MSG91 (not delivered)", num(w.all.failed), "", "r"],
                ["Refused by our limits (never sent)", num(w.all.blocked), `saved ${money(w.all.blocked * rate)}`, "g"],
              ].map(([label, n, amt, tone]) => (
                <tr key={label as string}>
                  <Td className="text-muted">{label}</Td>
                  <Td num className="font-extrabold">{n}</Td>
                  <Td num>
                    {amt ? <Pill tone={tone as any}>{amt}</Pill> : null}
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
          <p className="text-muted text-[11px] mt-2.5">
            “Sent but never verified” is the wasteful half of the bill — codes delivered to people who
            dropped off. Tightening the cooldown below cuts it directly.
          </p>
        </Card>

        <Card title="Failures & refusals">
          {d.failures.length ? (
            <Table>
              <thead>
                <tr><Th>What happened</Th><Th>Step</Th><Th num>Count</Th><Th>Last</Th></tr>
              </thead>
              <tbody>
                {d.failures.map((f) => (
                  <tr key={`${f.action}-${f.status}`}>
                    <Td>
                      <span className="font-semibold">{STATUS_LABEL[f.status] || f.status}</span>
                      {COSTLY.has(f.status) && <Pill tone="r">cost</Pill>}
                      {SAVED.has(f.status) && <Pill tone="g">saved</Pill>}
                    </Td>
                    <Td className="text-muted">{f.action}</Td>
                    <Td num className="font-extrabold">{num(f.n)}</Td>
                    <Td className="text-muted whitespace-nowrap">{when(f.last_seen)}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          ) : (
            <Empty action="Nothing to fix here — tighten the limits below only if the bill grows.">
              Everything sent cleanly
            </Empty>
          )}
        </Card>
      </div>

      <div className="grid gap-3.5 lg:grid-cols-2 items-start mt-3.5">
        <Card title="Price & budget">
          <p className="text-muted text-xs mb-3">
            What MSG91 charges you per WhatsApp template message. Nothing here changes the app — it only
            changes how spend is estimated on this page. Copy the real figure off your MSG91 invoice.
          </p>
          <div className="grid grid-cols-2 gap-3">
            <NumField
              label="₹ per message" step={0.01} value={cost.perMessage}
              help="WhatsApp authentication template rate"
              onChange={(v) => setCost({ ...cost, perMessage: v })}
            />
            <NumField
              label="Monthly budget (₹)" step={100} value={cost.monthlyBudget}
              help="0 = no budget bar"
              onChange={(v) => setCost({ ...cost, monthlyBudget: v })}
            />
          </div>
          <button
            className="btn mt-3 w-full"
            onClick={() => save("otp_cost", { currency: "INR", ...cost }, "price & budget")}
          >
            Save price
          </button>
        </Card>

        <Card title="Spend limits">
          <p className="text-muted text-xs mb-3">
            These are the real cost controls — the <code className="font-mono">otp</code> edge function reads
            them on every send, so a change takes effect immediately with no redeploy and no app update.
          </p>
          <div className="grid grid-cols-2 gap-3">
            <NumField
              label="Cooldown (s)" value={limits.cooldown}
              help="Minimum gap between codes to one phone"
              onChange={(v) => setLimits({ ...limits, cooldown: v })}
            />
            <NumField
              label="Sends / phone / hour" value={limits.maxSendPerHour}
              help="Caps one agent retrying"
              onChange={(v) => setLimits({ ...limits, maxSendPerHour: v })}
            />
            <NumField
              label="Sends / IP / hour" value={limits.maxIpPerHour}
              help="Caps one network across all phones"
              onChange={(v) => setLimits({ ...limits, maxIpPerHour: v })}
            />
            <NumField
              label="Sends / device / hour" value={limits.maxDevicePerHour}
              help="Anti-enumeration — the main anti-abuse cap"
              onChange={(v) => setLimits({ ...limits, maxDevicePerHour: v })}
            />
            <NumField
              label="Code lifetime (s)" value={limits.ttl}
              help="Shorter = more resends = more spend"
              onChange={(v) => setLimits({ ...limits, ttl: v })}
            />
            <NumField
              label="Wrong tries allowed" value={limits.maxAttempts}
              help="Then the code is burned"
              onChange={(v) => setLimits({ ...limits, maxAttempts: v })}
            />
          </div>
          <button
            className="btn mt-3 w-full"
            onClick={() => save("otp_limits", { ...(d.config?.otp_limits || {}), ...limits, digits: d.config?.otp_limits?.digits ?? 4 }, "spend limits")}
          >
            Save limits
          </button>
          <div className="flex items-center justify-between pt-3 mt-3 border-t border-line">
            <div className="pr-4">
              <div className="font-semibold text-sm">Require phone verification</div>
              <div className="text-muted text-xs">
                The master tap. Off = no OTPs are sent at all and the bill goes to zero — but nobody new can
                onboard. Also on the App Config page.
              </div>
            </div>
            <Toggle on={otpOn} onChange={(v) => save("otp_required", v, "verification switch")} />
          </div>
        </Card>
      </div>

      <Card
        title="Heaviest phones"
        className="mt-3.5"
        right={<span className="text-muted text-[11px]">by billable sends</span>}
      >
        {d.top.length ? (
          <>
            <Table>
              <thead>
                <tr><Th>Phone</Th><Th num>Sent</Th><Th num>Cost</Th><Th num>Verified</Th><Th num>Blocked</Th><Th>Last seen</Th></tr>
              </thead>
              <tbody>
                {d.top.map((p) => {
                  const dud = p.sent >= 3 && !p.verified;
                  return (
                    <tr key={p.phone_hash}>
                      <Td className="font-mono text-xs">
                        {p.phone_hash.slice(0, 10)}…
                        {dud && <Pill tone="r">never verified</Pill>}
                      </Td>
                      <Td num className="font-extrabold">{num(p.sent)}</Td>
                      <Td num>{money(p.sent * rate)}</Td>
                      <Td num>{num(p.verified)}</Td>
                      <Td num className="text-muted">{num(p.blocked)}</Td>
                      <Td className="text-muted whitespace-nowrap">{when(p.last_seen)}</Td>
                    </tr>
                  );
                })}
              </tbody>
            </Table>
            <p className="text-muted text-[11px] mt-2.5">
              Phone numbers are never stored — only a SHA-256 hash, so these are hash prefixes. A row with
              several sends and no verify is someone pulling paid messages without ever signing in.
            </p>
          </>
        ) : (
          <Empty action="Turn on “Require phone verification” above to start sending — until then this stays empty and the bill stays zero.">
            No OTP requests recorded
          </Empty>
        )}
      </Card>

      {saved && (
        <div className="fixed bottom-5 right-5 card px-4 py-2.5 text-green text-sm font-semibold shadow-lg">
          Saved {saved}.
        </div>
      )}
    </>
  );
}
