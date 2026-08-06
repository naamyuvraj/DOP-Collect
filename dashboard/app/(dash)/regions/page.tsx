"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Skel, Td, Th } from "@/components/ui";
import { num, when } from "@/lib/format";

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
  const [d, setD] = useState<Data | null>(null);
  useEffect(() => {
    fetch("/api/regions").then((r) => r.json()).then(setD);
  }, []);
  if (!d) {
    return (
      <>
        <PageHead title="Regions" subtitle="Where the app is used — installs & agents by post-office branch (SOL ID)" />
        <KpiSkeletons n={4} />
        <Card title="Branches / regions" className="mt-3.5"><Skel className="h-40 w-full" /></Card>
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
        <Card className="!bg-focal/40 mb-3.5">
          <div className="text-sm font-semibold">Install-level regions need the app update</div>
          <div className="text-muted text-[13px] mt-0.5">
            Regions below are derived from <b>subscribers</b> (their agent id carries the SOL ID). To map{" "}
            <b>every install</b> to a branch, the app must send its SOL ID with telemetry — run{" "}
            <code>admin/schema_regions.sql</code> and ship the app update that attaches it.
          </div>
        </Card>
      )}

      <div className="grid gap-3.5 grid-cols-2 md:grid-cols-4">
        <Kpi label="Regions (SOL IDs)" value={num(t.regions)} focal />
        <Kpi label="Installs mapped" value={num(t.installs_with_region)} sub={`${num(t.anonymous_installs)} anonymous`} />
        <Kpi label="Subscribers" value={num(t.subscribers)} />
        <Kpi label="Invalid IDs" value={num(t.invalid_ids)} />
      </div>

      <Card title="Branches / regions" className="mt-3.5">
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>SOL ID (branch)</Th>
                <Th>Installs</Th>
                <Th>Active 7d</Th>
                <Th>Subscribers</Th>
                <Th>Agents</Th>
                <Th>Usage</Th>
                <Th>Last seen</Th>
              </tr>
            </thead>
            <tbody>
              {d.regions.map((r) => (
                <tr key={r.sol_id}>
                  <Td className="font-mono text-xs font-bold">{r.sol_id}</Td>
                  <Td>{num(r.installs)}</Td>
                  <Td className="text-muted">{num(r.active_installs)}</Td>
                  <Td>{r.subscribers ? <Pill tone="g">{num(r.subscribers)}</Pill> : <span className="text-faint">0</span>}</Td>
                  <Td className="text-muted">{num(r.agents)}</Td>
                  <Td>
                    <div className="h-2 rounded-full bg-line w-28 overflow-hidden">
                      <div className="h-full bg-blue rounded-full" style={{ width: `${((r.installs + r.subscribers) / maxUse) * 100}%` }} />
                    </div>
                  </Td>
                  <Td className="text-muted text-xs whitespace-nowrap">{r.last_seen ? when(r.last_seen) : "—"}</Td>
                </tr>
              ))}
            </tbody>
          </table>
          {!d.regions.length && <Empty>No agent IDs seen yet — regions appear once subscribers or SOL-tagged installs exist.</Empty>}
        </div>
        <p className="text-muted text-xs mt-3">
          A DOP agent id is <span className="font-mono">MI</span> + <b>SOL ID</b> + a 5-digit sequence. The SOL ID is
          the attached post office, so grouping by it shows the branches/regions using the app.
        </p>
      </Card>
    </>
  );
}
