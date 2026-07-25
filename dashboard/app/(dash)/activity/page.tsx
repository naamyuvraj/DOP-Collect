import PageHead from "@/components/PageHead";
import { Card, Empty, Pill, Td, Th } from "@/components/ui";
import { recent } from "@/lib/data";
import { shortId, when } from "@/lib/format";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Ev = {
  device_id: string;
  event: string;
  props: Record<string, unknown>;
  app_version: string | null;
  created_at: string;
};

export default async function Activity() {
  const events = await recent<Ev>(
    "events",
    "device_id,event,props,app_version,created_at",
    150
  );

  return (
    <>
      <PageHead title="Activity" subtitle="Latest 150 events" />
      <Card>
        <div className="overflow-x-auto">
          <table className="w-full text-[13px]">
            <thead>
              <tr>
                <Th>When</Th>
                <Th>Device</Th>
                <Th>Event</Th>
                <Th>Details</Th>
                <Th>Version</Th>
              </tr>
            </thead>
            <tbody>
              {events.map((e, i) => (
                <tr key={i}>
                  <Td className="text-muted whitespace-nowrap">{when(e.created_at)}</Td>
                  <Td className="font-mono text-xs">{shortId(e.device_id)}</Td>
                  <Td><Pill>{e.event}</Pill></Td>
                  <Td className="text-muted text-xs">
                    {Object.entries(e.props || {})
                      .map(([k, v]) => `${k}:${v}`)
                      .join(" · ")}
                  </Td>
                  <Td className="text-muted text-xs">{e.app_version || "—"}</Td>
                </tr>
              ))}
            </tbody>
          </table>
          {!events.length && <Empty>No activity yet.</Empty>}
        </div>
      </Card>
    </>
  );
}
