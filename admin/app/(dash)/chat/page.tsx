"use client";
import { useEffect, useState } from "react";
import PageHead from "@/components/PageHead";
import ReloadButton from "@/components/ReloadButton";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Table, Td, Th } from "@/components/ui";
import { usePersisted } from "@/lib/uiState";
import type { ChatData, ChatSlice } from "@/app/api/chat/route";

const WINDOWS = [7, 30, 90];

/** A share bar. Failures are drawn inside the bar, not beside it, so a source
 *  that is busy AND unreliable reads as one shape rather than two numbers. */
function Bars({ rows, empty }: { rows: ChatSlice[]; empty: string }) {
  if (!rows.length) return <Empty>{empty}</Empty>;
  const max = Math.max(...rows.map((r) => r.n), 1);
  return (
    <div className="space-y-2">
      {rows.map((r) => (
        <div key={r.key} className="flex items-center gap-3">
          <div className="w-32 shrink-0 truncate text-sm" title={r.key}>{r.key}</div>
          <div className="relative h-5 flex-1 overflow-hidden rounded bg-neutral-100">
            <div className="absolute inset-y-0 left-0 bg-neutral-800"
                 style={{ width: `${(r.n / max) * 100}%` }} />
            {r.failed > 0 && (
              <div className="absolute inset-y-0 left-0 bg-red-500"
                   style={{ width: `${(r.failed / max) * 100}%` }} />
            )}
          </div>
          <div className="w-24 shrink-0 text-right text-sm tabular-nums">
            {r.n}
            {r.failed > 0 && <span className="ml-1 text-red-600">·{r.failed}</span>}
          </div>
        </div>
      ))}
    </div>
  );
}

export default function Chat() {
  const [d, setD] = useState<ChatData | null>(null);
  const [days, setDays] = usePersisted<number>("chat.days", 30);

  async function load(n = days) {
    setD(null);
    setD(await fetch(`/api/chat?days=${n}`, { cache: "no-store" }).then((x) => x.json()));
  }
  useEffect(() => { load(days); /* eslint-disable-next-line */ }, [days]);

  const failRate = d && d.total ? Math.round((d.failed / d.total) * 100) : 0;
  const localRate = d && d.total ? Math.round((d.answeredLocally / d.total) * 100) : 0;

  return (
    <>
      <PageHead
        title="Agent Chat"
        subtitle="How the assistant on the agents' handsets is performing"
        right={<ReloadButton onReload={() => load()} />}
      />

      <div className="mb-4 flex gap-2">
        {WINDOWS.map((n) => (
          <button key={n} onClick={() => setDays(n)}
            className={`rounded-full px-3 py-1 text-sm ${
              days === n ? "bg-neutral-900 text-white" : "bg-neutral-100 text-neutral-600"}`}>
            {n}d
          </button>
        ))}
      </div>

      {!d ? <KpiSkeletons n={4} /> : (
        <>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Kpi label="Questions" value={String(d.total)} />
            <Kpi label="Failed" value={`${d.failed}`} sub={`${failRate}% of all`} />
            <Kpi label="Answered on device" value={`${localRate}%`}
                 sub="no network, no Groq cost" />
            <Kpi label="Actions run" value={String(d.actions)} />
          </div>

          <div className="mt-6 grid gap-6 md:grid-cols-2">
            <Card title="Where answers came from">
              <p className="mb-3 text-xs text-neutral-500">local = answered on the handset. groq = sent to the model.</p>
              <Bars rows={d.bySource} empty="No queries in this window." />
            </Card>
            <Card title="What was asked about">
              <p className="mb-3 text-xs text-neutral-500">The answer's shape — a list, a count, a calculation.</p>
              <Bars rows={d.byKind} empty="No queries in this window." />
            </Card>
            <Card title="Language">
              <Bars rows={d.byLang} empty="No queries in this window." />
            </Card>
            <Card title="Groq model reliability">
              <p className="mb-3 text-xs text-neutral-500">Red is calls the provider rejected. A model failing here is the likeliest cause of a dead answer on the handset.</p>
              <Bars rows={d.byModel} empty="No Groq calls in this window." />
            </Card>
            <Card title="By app build">
              <p className="mb-3 text-xs text-neutral-500">A build with a higher failure share is a regression worth chasing.</p>
              <Bars rows={d.byVersion} empty="No queries in this window." />
            </Card>
            <Card title="Busiest handsets">
              {d.topDevices.length ? (
                <Table>
                  <thead><tr><Th>Device</Th><Th>Questions</Th><Th>Failed</Th></tr></thead>
                  <tbody>
                  {d.topDevices.map((t) => (
                    <tr key={t.device}>
                      <Td><span className="font-mono text-xs">{t.device.slice(0, 8)}</span></Td>
                      <Td>{t.n}</Td>
                      <Td>{t.failed ? <Pill tone="r">{t.failed}</Pill> : "—"}</Td>
                    </tr>
                  ))}
                  </tbody>
                </Table>
              ) : <Empty>No queries in this window.</Empty>}
            </Card>
          </div>

          {d.perDay.length > 1 && (
            <Card title="Questions per day" className="mt-6">
              <div className="flex h-28 items-end gap-1">
                {d.perDay.map((p) => {
                  const max = Math.max(...d.perDay.map((x) => x.total), 1);
                  return (
                    <div key={p.day} className="flex-1" title={`${p.day} · ${p.total} (${p.failed} failed)`}>
                      <div className="mx-auto w-full rounded-t bg-red-500"
                           style={{ height: `${(p.failed / max) * 100}%` }} />
                      <div className="mx-auto w-full rounded-t bg-neutral-800"
                           style={{ height: `${((p.total - p.failed) / max) * 100}%` }} />
                    </div>
                  );
                })}
              </div>
            </Card>
          )}

          {!!d.notes.length && (
            <div className="mt-6 space-y-1 text-sm text-neutral-500">
              {d.notes.map((n) => <p key={n}>{n}</p>)}
            </div>
          )}
        </>
      )}
    </>
  );
}
