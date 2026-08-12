import PageHead from "@/components/PageHead";
import { Bars, Donut, TrendArea } from "@/components/LazyCharts";
import { Card, Empty, Kpi, Pill, Td, Th } from "@/components/ui";
import {
  getCollections,
  getDaily,
  getEventTypes,
  getKeyUsage,
  getRevenueByDay,
  getSummary,
  recent,
} from "@/lib/data";
import { computeUsers } from "@/lib/users";
import { day, inr, num, shortId, when } from "@/lib/format";

// Cache the analytics render for 60s (ISR) instead of re-querying Supabase on
// every navigation. Usage stats don't need to be second-fresh, and this makes
// repeat visits + prefetched links load instantly.
export const revalidate = 60;

type Ev = {
  device_id: string;
  event: string;
  props: Record<string, unknown>;
  created_at: string;
};

export default async function Overview() {
  const [s, daily, types, keys, rev, coll, users, events] = await Promise.all([
    getSummary(),
    getDaily(),
    getEventTypes(),
    getKeyUsage(),
    getRevenueByDay(),
    getCollections(),
    computeUsers(),
    recent<Ev>("events", "device_id,event,props,created_at", 12),
  ]);
  const t = users.totals;
  const avgAcc = t.agents ? Math.round(t.accounts / t.agents) : 0;

  const dailyView = daily.slice(-30).map((d) => ({ ...d, d: day(d.day) }));
  const revView = rev.slice(-30).map((d) => ({ ...d, d: day(d.day) }));
  const collView = coll.slice(-30).map((d) => ({ ...d, d: day(d.day) }));
  const keyView = keys.map((k) => ({ ...k, name: `Key ${k.key_index}` }));

  return (
    <>
      <PageHead title="Overview" subtitle="Agents, their books, and app activity" />

      {/* Agent-level headline — one DOP agent = one unit (phones deduped) */}
      <div className="grid gap-3.5 grid-cols-2 md:grid-cols-3 lg:grid-cols-6">
        <Kpi label="Agents" value={num(t.agents)} sub={`${num(t.verified)} verified`} />
        <Kpi label="Active · 7d" value={num(t.active)} />
        <Kpi label="Accounts" value={num(t.accounts)} sub={`~${num(avgAcc)}/agent`} />
        <Kpi label="Under management ₹" value={inr(t.value)} sub="deposited across books" focal />
        <Kpi label="Collected ₹" value={inr(t.collected)} sub={`${num(t.lists)} lists on portal`} />
        <Kpi label="Installs" value={num(t.installs)} sub="phones" />
      </div>

      {/* Supporting — money & engagement */}
      <div className="grid gap-3.5 grid-cols-2 md:grid-cols-4 mt-3.5">
        <Kpi label="Revenue (subs) ₹" value={inr(s.revenue)} />
        <Kpi label="Subscribers" value={num(t.subscribers)} />
        <Kpi label="AI queries" value={num(t.ai_queries)} />
        <Kpi label="Key calls · 24h" value={num(s.key_calls_1d)} />
      </div>

      <div className="grid gap-3.5 mt-3.5 lg:grid-cols-[1.4fr_1fr]">
        <Card title="Daily active devices">
          {dailyView.length ? (
            <TrendArea data={dailyView} x="d" y="dau" />
          ) : (
            <Empty>No activity yet.</Empty>
          )}
        </Card>
        <Card title="LLM key usage">
          {keyView.length ? (
            <Donut data={keyView} nameKey="name" valueKey="calls" />
          ) : (
            <Empty>No key calls yet.</Empty>
          )}
        </Card>
      </div>

      <div className="grid gap-3.5 mt-3.5 lg:grid-cols-2">
        <Card title="Portal collections (₹/day)">
          {collView.some((c) => c.amount) ? (
            <Bars data={collView} x="d" y="amount" color="#21A06A" />
          ) : (
            <Empty>No lists made on the portal yet.</Empty>
          )}
        </Card>
        <Card title="Lists made on portal">
          {collView.some((c) => c.lists) ? (
            <TrendArea data={collView} x="d" y="lists" />
          ) : (
            <Empty>No lists made on the portal yet.</Empty>
          )}
        </Card>
      </div>

      <div className="grid gap-3.5 mt-3.5 lg:grid-cols-2">
        <Card title="Activity by type">
          {types.length ? (
            <Bars data={types.slice(0, 8)} x="event" y="n" horizontal />
          ) : (
            <Empty>No events yet.</Empty>
          )}
        </Card>
        <Card title="Revenue (app subscriptions)">
          {revView.some((r) => r.revenue) ? (
            <Bars data={revView} x="d" y="revenue" color="#EFE94C" />
          ) : (
            <Empty>No payments yet.</Empty>
          )}
        </Card>
      </div>

      <Card title="Recent activity" className="mt-3.5">
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>When</Th>
                <Th>Device</Th>
                <Th>Event</Th>
                <Th>Details</Th>
              </tr>
            </thead>
            <tbody>
              {events.map((e, i) => (
                <tr key={i}>
                  <Td className="whitespace-nowrap text-muted">{when(e.created_at)}</Td>
                  <Td className="font-mono text-xs">{shortId(e.device_id)}</Td>
                  <Td><Pill>{e.event}</Pill></Td>
                  <Td className="text-muted text-xs">
                    {Object.entries(e.props || {})
                      .map(([k, v]) => `${k}:${v}`)
                      .join(" · ")}
                  </Td>
                </tr>
              ))}
              {!events.length && (
                <tr><Td className="text-muted" >No activity yet.</Td></tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>
    </>
  );
}
