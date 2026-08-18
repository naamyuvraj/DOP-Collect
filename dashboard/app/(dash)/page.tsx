import Link from "next/link";
import PageHead from "@/components/PageHead";
import { Bars, Donut, TrendArea } from "@/components/LazyCharts";
import { Card, Empty, Kpi, Pill, Table, Td, Th } from "@/components/ui";
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
      <PageHead title="Overview" subtitle="Agents · books · activity" />

      {/* The book leads. Everything on this page is downstream of how much RD
          the agents are carrying, so it is the tile that gets the size — the
          rest of the row qualifies it, and the row below only counts things. */}
      <div className="grid gap-4 grid-cols-2 md:grid-cols-3 lg:grid-cols-6 stagger">
        <Kpi icon="value" label="Monthly book" value={inr(t.value)} sub="RD / month" focal wide href="/devices" />
        <Kpi icon="agents" label="Agents" value={num(t.agents)} sub={`${num(t.verified)} verified`} href="/devices" />
        <Kpi icon="active" label="Active" value={num(t.active)} sub="7 days" href="/activity" />
        <Kpi icon="accounts" label="Accounts" value={num(t.accounts)} sub={`~${num(avgAcc)}/agent`} href="/devices" />
        <Kpi icon="collected" label="Collected" value={inr(t.collected)} sub={`${num(t.lists)} lists`} href="/devices" />
      </div>

      <div className="grid gap-4 grid-cols-2 md:grid-cols-5 mt-4 stagger">
        <Kpi icon="installs" label="Installs" value={num(t.installs)} sub="phones" minor href="/releases" />
        <Kpi icon="revenue" label="Revenue" value={inr(s.revenue)} minor href="/payments" />
        {/* Paying only — a free trial is not a subscriber. Said out loud because
            this tile read 1 while both agents were on trial. */}
        <Kpi icon="subscribers" label="Subscribers" value={num(t.subscribers)} sub="paying" minor href="/plans" />
        <Kpi icon="ai" label="AI" value={num(t.ai_queries)} minor href="/assistant" />
        <Kpi icon="keys" label="Keys" value={num(s.key_calls_1d)} sub="24h" minor href="/keys" />
      </div>

      <div className="grid gap-4 mt-4 lg:grid-cols-[1.4fr_1fr]">
        <Card title="Active · daily">
          {dailyView.length ? (
            <TrendArea data={dailyView} x="d" y="dau" />
          ) : (
            <Empty action="Install the APK on a handset and sign in — the first launch lands here.">
              No agent has opened the app yet
            </Empty>
          )}
        </Card>
        <Card title="Key usage">
          {keyView.length ? (
            <Donut data={keyView} nameKey="name" valueKey="calls" />
          ) : (
            <Empty action={<>Add a Groq key on <Link className="lnk" href="/keys">API Keys</Link>, then ask the Assistant something.</>}>
              No key calls yet
            </Empty>
          )}
        </Card>
      </div>

      <div className="grid gap-4 mt-4 lg:grid-cols-2">
        <Card title="Collections · ₹/day">
          {collView.some((c) => c.amount) ? (
            <Bars data={collView} x="d" y="amount" color="#21A06A" />
          ) : (
            <Empty action="Ask an agent to submit a list on the portal — the amount is stamped as it goes.">
              Nothing collected yet
            </Empty>
          )}
        </Card>
        <Card title="Lists · daily">
          {collView.some((c) => c.lists) ? (
            <TrendArea data={collView} x="d" y="lists" />
          ) : (
            <Empty action="Ask an agent to submit their first list on the portal.">
              No lists filed yet
            </Empty>
          )}
        </Card>
      </div>

      <div className="grid gap-4 mt-4 lg:grid-cols-2">
        <Card title="Activity">
          {types.length ? (
            <Bars data={types.slice(0, 8)} x="event" y="n" horizontal />
          ) : (
            <Empty action={<>Check a handset is signed in — see <Link className="lnk" href="/devices">Users</Link>.</>}>
              No events recorded
            </Empty>
          )}
        </Card>
        <Card title="Revenue">
          {revView.some((r) => r.revenue) ? (
            <Bars data={revView} x="d" y="revenue" color="#EFE94C" />
          ) : (
            <Empty action={<>Price a tier on <Link className="lnk" href="/plans">Plans</Link>, then switch payments on there.</>}>
              Nothing sold yet
            </Empty>
          )}
        </Card>
      </div>

      <Card
        title="Latest activity"
        className="mt-4"
        right={<Link className="lnk text-body" href="/activity">All events →</Link>}
      >
        <Table>
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
          </tbody>
        </Table>
        {!events.length && (
          <Empty action={<>Check a handset is signed in — see <Link className="lnk" href="/devices">Users</Link>.</>}>
            No activity yet
          </Empty>
        )}
      </Card>
    </>
  );
}
