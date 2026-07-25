import PageHead from "@/components/PageHead";
import { Card, Empty, Pill, Td, Th } from "@/components/ui";
import { recent } from "@/lib/data";
import { shortId, when } from "@/lib/format";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Device = {
  id: string;
  agent_name: string | null;
  app_version: string | null;
  model: string | null;
  first_seen: string;
  last_seen: string;
};

function activeTone(last: string) {
  const days = (Date.now() - new Date(last).getTime()) / 864e5;
  if (days < 1) return { tone: "g" as const, txt: "active today" };
  if (days < 7) return { tone: "b" as const, txt: "this week" };
  return { tone: "r" as const, txt: "dormant" };
}

export default async function Devices() {
  const devices = await recent<Device>(
    "devices",
    "id,agent_name,app_version,model,first_seen,last_seen",
    500,
    "last_seen"
  );

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
                    <Td className="text-muted whitespace-nowrap">{when(d.first_seen)}</Td>
                    <Td className="text-muted whitespace-nowrap">{when(d.last_seen)}</Td>
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
