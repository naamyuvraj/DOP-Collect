import PageHead from "@/components/PageHead";
import { Card, Empty, Pill, Td, Th } from "@/components/ui";
import { getDevices } from "@/lib/data";
import { num, shortId, when } from "@/lib/format";

export const revalidate = 60; // ISR: instant repeat loads, data ≤60s stale.

function activeTone(last: string | null) {
  if (!last) return { tone: "r" as const, txt: "dormant" };
  const days = (Date.now() - new Date(last).getTime()) / 864e5;
  if (days < 1) return { tone: "g" as const, txt: "active today" };
  if (days < 7) return { tone: "b" as const, txt: "this week" };
  return { tone: "r" as const, txt: "dormant" };
}

export default async function Devices() {
  // v_devices = the devices table UNION everyone who has sent events, so a real
  // user shows up even if the identify() upsert never landed.
  const devices = await getDevices();

  return (
    <>
      <PageHead
        title="Users & Devices"
        subtitle={`${devices.length} installs`}
      />
      <Card>
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>Agent</Th>
                <Th>Device ID</Th>
                <Th>Version</Th>
                <Th>Events</Th>
                <Th>First seen</Th>
                <Th>Last seen</Th>
                <Th>Status</Th>
              </tr>
            </thead>
            <tbody>
              {devices.map((d) => {
                const a = activeTone(d.last_seen);
                return (
                  <tr key={d.id}>
                    <Td className="font-semibold">{d.agent_name || "—"}</Td>
                    <Td className="font-mono text-xs">{shortId(d.id)}</Td>
                    <Td>{d.app_version || "—"}</Td>
                    <Td className="mono">{num(d.events)}</Td>
                    <Td className="text-muted whitespace-nowrap">{d.first_seen ? when(d.first_seen) : "—"}</Td>
                    <Td className="text-muted whitespace-nowrap">{d.last_seen ? when(d.last_seen) : "—"}</Td>
                    <Td><Pill tone={a.tone}>{a.txt}</Pill></Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {!devices.length && <Empty>No installs yet.</Empty>}
        </div>
      </Card>
    </>
  );
}
