import PageHead from "@/components/PageHead";
import { Card } from "@/components/ui";
import ReloadButton from "@/components/ReloadButton";
import { recent } from "@/lib/data";
import ActivityTable, { type Ev } from "./ActivityTable";

export const revalidate = 60; // ISR: instant repeat loads, data ≤60s stale.

export default async function Activity() {
  const events = await recent<Ev>(
    "events",
    "device_id,event,props,app_version,created_at",
    150
  );

  return (
    <>
      <PageHead
        title="Activity"
        subtitle="Latest 150 events"
        right={<ReloadButton path="/activity" />}
      />
      <Card>
        <ActivityTable events={events} />
      </Card>
    </>
  );
}
