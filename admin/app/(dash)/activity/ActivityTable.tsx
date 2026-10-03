"use client";
import { useMemo } from "react";
import { usePersisted } from "@/lib/uiState";
import { Empty, Pill, Table, Td, Th } from "@/components/ui";
import { shortId, when } from "@/lib/format";

export type Ev = {
  device_id: string;
  event: string;
  props: Record<string, unknown>;
  app_version: string | null;
  created_at: string;
};

const detail = (p: Record<string, unknown>) =>
  Object.entries(p || {}).map(([k, v]) => `${k}:${v}`).join(" · ");

/**
 * Filtering lives on the client over the already-fetched page of events.
 * 150 rows is small enough that round-tripping every keystroke would be slower
 * and would spend a Supabase query per character — and the event list is the
 * one place you are usually hunting for a single row.
 */
export default function ActivityTable({ events }: { events: Ev[] }) {
  const [q, setQ] = usePersisted("activity.q", "");
  const [event, setEvent] = usePersisted("activity.event", "all");
  const [version, setVersion] = usePersisted("activity.version", "all");

  // Built from what actually arrived, so a new event type needs no code change.
  const types = useMemo(
    () => [...new Set(events.map((e) => e.event))].sort(),
    [events]
  );
  const versions = useMemo(
    () => [...new Set(events.map((e) => e.app_version).filter(Boolean))].sort().reverse() as string[],
    [events]
  );

  const view = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return events.filter((e) => {
      if (event !== "all" && e.event !== event) return false;
      if (version !== "all" && e.app_version !== version) return false;
      if (!needle) return true;
      return [e.device_id, e.event, e.app_version, detail(e.props)]
        .join(" ").toLowerCase().includes(needle);
    });
  }, [events, q, event, version]);

  const filtered = !!q || event !== "all" || version !== "all";
  const clear = () => { setQ(""); setEvent("all"); setVersion("all"); };

  return (
    <>
      <div className="flex flex-wrap items-center gap-2 mb-4 pb-4 border-b border-line">
        <input
          className="input max-w-xs"
          placeholder="Search device, event, details…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
        <select className="input w-auto min-w-[150px]" value={event} onChange={(e) => setEvent(e.target.value)}>
          <option value="all">All events</option>
          {types.map((t) => <option key={t} value={t}>{t}</option>)}
        </select>
        <select className="input w-auto min-w-[130px]" value={version} onChange={(e) => setVersion(e.target.value)}>
          <option value="all">Any version</option>
          {versions.map((v) => <option key={v} value={v}>{v}</option>)}
        </select>
        {filtered && <button className="lnk text-meta" onClick={clear}>Clear</button>}
        <span className="ml-auto text-muted text-meta tabular-nums">
          {view.length} of {events.length}
        </span>
      </div>

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
          {view.map((e, i) => (
            <tr key={i}>
              <Td className="text-muted whitespace-nowrap">{when(e.created_at)}</Td>
              <Td className="font-mono text-meta">{shortId(e.device_id)}</Td>
              <Td><Pill tone="b">{e.event}</Pill></Td>
              <Td className="text-muted text-meta">{detail(e.props)}</Td>
              <Td className="text-muted text-meta">{e.app_version || "—"}</Td>
            </tr>
          ))}
        </tbody>
      </Table>

      {!view.length && (
        filtered ? (
          <Empty action={<button className="lnk" onClick={clear}>Clear the search and filters</button>}>
            No events match these filters
          </Empty>
        ) : (
          <Empty action="Nothing has reached the database yet.">No events recorded</Empty>
        )
      )}
    </>
  );
}
