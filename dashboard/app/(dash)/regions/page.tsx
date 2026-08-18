"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel, Table, Td, Th } from "@/components/ui";
import { num, when } from "@/lib/format";
import { peekCached, isFresh, setCached } from "@/lib/clientCache";

type Region = {
  sol_id: string;
  installs: number;
  active_installs: number;
  subscribers: number;
  agents: number;
  last_seen?: string;
};
type Data = {
  regions: Region[];
  totals: {
    regions?: number;
    installs?: number;
    installs_with_region?: number;
    anonymous_installs?: number;
    subscribers?: number;
    invalid_ids?: number;
  };
  device_region_ready?: boolean;
};

export default function Regions() {
  const [d, setD] = useState<Data | null>(() => peekCached<Data>("regions"));
  useEffect(() => {
    if (isFresh("regions")) return;
    fetch("/api/regions", { cache: "no-store" }).then((r) => r.json()).then((x) => { setCached("regions", x); setD(x); });
  }, []);
  if (!d) {
    return (
      <>
        <PageHead title="Regions" subtitle="Where the app is used — installs & agents by post-office branch (SOL ID)" />
        <KpiSkeletons n={4} grid="grid-cols-2 md:grid-cols-4" focal />
        <Card title="Branches / regions" className="mt-4"><Skel className="h-40 w-full" /></Card>
      </>
    );
  }

  const t = d.totals || {};
  const maxUse = Math.max(1, ...d.regions.map((r) => r.installs + r.subscribers));

  return (
    <>
      <PageHead
        title="Regions"
        subtitle="Where the app is used — installs & agents by post-office branch (SOL ID)"
      />

      {!d.device_region_ready && (
        <Card className="!bg-canvas mb-3.5">
          <div className="text-sm font-semibold">Install-level regions need the app update</div>
          <div className="text-muted text-body mt-0.5">
            Regions below are derived from <b>subscribers</b> (their agent id carries the SOL ID). To map{" "}
            <b>every install</b> to a branch, the app must send its SOL ID with telemetry — run{" "}
            <code>admin/schema_regions.sql</code> and ship the app update that attaches it.
          </div>
        </Card>
      )}

      <div className="grid gap-4 grid-cols-2 md:grid-cols-4 stagger">
        <Kpi label="Regions (SOL IDs)" value={num(t.regions)} sub="post-office branches using the app" focal />
        <Kpi label="Installs mapped" value={num(t.installs_with_region)} sub={`${num(t.anonymous_installs)} anonymous`} />
        <Kpi label="Subscribers" value={num(t.subscribers)} />
        <Kpi label="Invalid IDs" value={num(t.invalid_ids)} />
      </div>

      <Card title="Branches / regions" className="mt-4">
        <Table>
          <thead>
            <tr>
              <Th>SOL ID (branch)</Th>
              <Th num>Installs</Th>
              <Th num>Active 7d</Th>
              <Th num>Subscribers</Th>
              <Th num>Agents</Th>
              <Th>Usage</Th>
              <Th>Last seen</Th>
            </tr>
          </thead>
          <tbody>
            {d.regions.map((r) => (
              <tr key={r.sol_id}>
                <Td className="font-mono text-xs font-semibold">{r.sol_id}</Td>
                <Td num className="font-semibold">{num(r.installs)}</Td>
                <Td num className="text-muted">{num(r.active_installs)}</Td>
                <Td num>{r.subscribers ? <Pill tone="g">{num(r.subscribers)}</Pill> : <span className="text-faint">0</span>}</Td>
                <Td num className="text-muted">{num(r.agents)}</Td>
                <Td>
                  <div className="h-2 rounded-full bg-line w-28 overflow-hidden">
                    <div className="h-full bg-accent rounded-full" style={{ width: `${((r.installs + r.subscribers) / maxUse) * 100}%` }} />
                  </div>
                </Td>
                <Td className="text-muted text-xs whitespace-nowrap">{r.last_seen ? when(r.last_seen) : "—"}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!d.regions.length && (
          <Empty action={<>Ask an agent to sign in with their DOP agent id — see <Link className="lnk" href="/devices">Users</Link> for who has.</>}>
            No branches mapped yet
          </Empty>
        )}
        <p className="text-muted text-xs mt-3">
          A DOP agent id is <span className="font-mono">MI</span> + <b>SOL ID</b> + a 5-digit sequence. The SOL ID is
          the attached post office, so grouping by it shows the branches/regions using the app.
        </p>
      </Card>
    </>
  );
}
