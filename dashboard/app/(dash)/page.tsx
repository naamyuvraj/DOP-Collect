import Link from "next/link";
import PageHead from "@/components/PageHead";
import TimeChart from "@/components/TimeChart";
import AggregateChart from "./AggregateChart";
import { Card, Empty, Kpi, Pill, Table, Td, Th } from "@/components/ui";
import {
  getCollections,
  getDaily,
  getRevenueByDay,
  getSummary,
  recent,
} from "@/lib/data";
import { computeUsers } from "@/lib/users";
import { inr, num, shortId, when } from "@/lib/format";

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
  const [s, daily, rev, coll, users, events, keyRows] = await Promise.all([
    getSummary(),
    getDaily(),
    getRevenueByDay(),
    getCollections(),
    computeUsers(),
    // Raw rows, not the pre-aggregated views: v_events_by_type and v_key_usage
    // carry no date column, so their charts could never honour a time window.
    recent<Ev>("events", "device_id,event,props,created_at", 2000),
    recent<{ key_index: number; model: string; ok: boolean; created_at: string }>(
      "key_usage", "key_index,model,ok,created_at", 2000
    ),
  ]);
  const t = users.totals;
  const avgAcc = t.agents ? Math.round(t.accounts / t.agents) : 0;

  // Windowing happens in the cards now, so the full series goes down.
  const eventRows = events.map((e) => ({ at: e.created_at, key: e.event }));
  const keyUsageRows = keyRows.map((k) => ({ at: k.created_at, key: `Key ${k.key_index}` }));

  return (
    <>
      <PageHead title="Overview" subtitle="Agents · books · activity" />

      {/* The book leads. Everything on this page is downstream of how much RD
          the agents are carrying, so it is the tile that gets the size — the
          rest of the row qualifies it, and the row below only counts things. */}
      <div className="grid gap-4 grid-cols-2 md:grid-cols-3 lg:grid-cols-7 stagger">
        <Kpi icon="value" label="Monthly book" value={inr(t.value)} sub="RD / month" focal wide href="/devices" />
        <Kpi icon="agents" label="Agents" value={num(t.agents)} sub={`${num(t.verified)} verified`}  href="/devices" />
        <Kpi icon="active" label="Active" value={num(t.active)} sub="7 days"  href="/activity" />
        <Kpi icon="accounts" label="Accounts" value={num(t.accounts)} sub={`~${num(avgAcc)}/agent`}  href="/devices" />
        <Kpi icon="collected" label="Collected" value={inr(t.collected)} sub={`${num(t.lists)} lists`} tone="accent" wide href="/devices" />
      </div>

      <div className="grid gap-4 grid-cols-2 md:grid-cols-5 mt-4 stagger">
        <Kpi icon="installs" label="Installs" value={num(t.installs)} sub="phones" minor href="/releases" />
        <Kpi icon="revenue" label="Revenue" value={inr(s.revenue)} minor  href="/payments" />
        {/* Paying only — a free trial is not a subscriber. Said out loud because
            this tile read 1 while both agents were on trial. */}
        <Kpi icon="subscribers" label="Subscribers" value={num(t.subscribers)} sub="paying" minor  href="/plans" />
        <Kpi icon="ai" label="AI" value={num(t.ai_queries)} minor  href="/assistant" />
        <Kpi icon="keys" label="Keys" value={num(s.key_calls_1d)} sub="24h" minor  href="/keys" />
      </div>

      <div className="grid gap-4 mt-4 lg:grid-cols-[1.4fr_1fr]">
        <TimeChart
          title="Active · daily"
          storageKey="dau"
          data={daily}
          series={[{ key: "dau", color: "#171C22", label: "Active" }]}
          empty="No agent has opened the app in this window"
        />
        <AggregateChart
          title="Key usage"
          storageKey="keyusage"
          rows={keyUsageRows}
          kind="donut"
          empty="No key calls in this window"
        />
      </div>

      <div className="grid gap-4 mt-4 lg:grid-cols-2">
        <TimeChart
          title="Collections · ₹/day"
          storageKey="collections"
          data={coll}
          kind="bars"
          series={[{ key: "amount", color: "#EDF751", label: "Collected" }]}
          empty="Nothing collected in this window"
        />
        <TimeChart
          title="Lists · daily"
          storageKey="lists"
          data={coll}
          series={[{ key: "lists", color: "#171C22", label: "Lists" }]}
          empty="No lists filed in this window"
        />
      </div>

      <div className="grid gap-4 mt-4 lg:grid-cols-2">
        <AggregateChart
          title="Activity"
          storageKey="eventtypes"
          rows={eventRows}
          empty="No events in this window"
        />
        <TimeChart
          title="Revenue"
          storageKey="revenue"
          data={rev}
          kind="bars"
          series={[{ key: "revenue", color: "#171C22", label: "Revenue" }]}
          empty="Nothing sold in this window"
        />
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
            {events.slice(0, 12).map((e, i) => (
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
