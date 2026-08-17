import Link from "next/link";
import PageHead from "@/components/PageHead";
import { Card, Empty, Pill, Table, Td, Th } from "@/components/ui";
import { recent } from "@/lib/data";
import { shortId, when } from "@/lib/format";

export const revalidate = 60; // ISR: instant repeat loads, data ≤60s stale.

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
        <Table>
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
        </Table>
        {!events.length && (
          <Empty action={<>Nothing has reached the database. Check a handset is signed in on <Link className="lnk" href="/devices">Users</Link>.</>}>
            No events recorded
          </Empty>
        )}
      </Card>
    </>
  );
}
