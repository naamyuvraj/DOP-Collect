"use client";
import { useEffect, useMemo, useState } from "react";
import PageHead from "@/components/PageHead";
import ReloadButton from "@/components/ReloadButton";
import { Card, Empty, Kpi, KpiSkeletons, Pill, Table, Td, Th } from "@/components/ui";
import { when } from "@/lib/format";
import { usePersisted } from "@/lib/uiState";
import type { ErrRow } from "@/app/api/errors/route";

type Data = { rows: ErrRow[]; sources: Record<string, number>; notes?: string[] };

const SOURCES: { key: string; label: string; hint: string }[] = [
  { key: "app", label: "App", hint: "Crashes and handled failures reported by a handset" },
  { key: "llm", label: "Assistant", hint: "Groq calls the provider rejected" },
  { key: "otp", label: "OTP", hint: "Sends that failed or were refused by the limits" },
  { key: "payment", label: "Payments", hint: "Charges that did not settle" },
];

const toneOf = (s: string) => (s === "payment" ? "r" : s === "app" ? "r" : s === "otp" ? "a" : "b");

export default function Errors() {
  const [d, setD] = useState<Data | null>(null);
  const [source, setSource] = usePersisted<string>("errors.source", "all");
  const [q, setQ] = usePersisted("errors.q", "");
  const [open, setOpen] = useState<string | null>(null);

  async function load() {
    const r = await fetch("/api/errors", { cache: "no-store" }).then((x) => x.json());
    setD(r);
  }
  useEffect(() => { load(); }, []);

  const rows = d?.rows ?? [];
  const view = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return rows.filter((r) => {
      if (source !== "all" && r.source !== source) return false;
      if (!needle) return true;
      return [r.kind, r.message, r.detail, r.subject, r.version].join(" ").toLowerCase().includes(needle);
    });
  }, [rows, source, q]);

  const last24 = rows.filter((r) => Date.now() - new Date(r.at).getTime() < 864e5).length;
  const filtered = source !== "all" || !!q;

  return (
    <>
      <PageHead
        title="Errors"
        subtitle="Everything that failed — app, assistant, OTP and payments in one place"
        right={<ReloadButton onReload={load} />}
      />

      {!d ? (
        <KpiSkeletons n={4} grid="grid-cols-2 md:grid-cols-4" />
      ) : (
        <div className="grid gap-4 grid-cols-2 md:grid-cols-4 stagger">
          <Kpi label="Last 24 hours" value={String(last24)} sub={`${rows.length} on record`} focal={last24 > 0} />
          {SOURCES.map((s) => (
            <Kpi key={s.key} label={s.label} value={String(d.sources?.[s.key] ?? 0)} sub={s.hint} minor />
          ))}
        </div>
      )}

      <Card title="Log" className="mt-4">
        <div className="flex flex-wrap items-center gap-2 mb-4 pb-4 border-b border-line">
          <input className="input max-w-xs" placeholder="Search message, device, version…"
                 value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="inline-flex rounded-[4px] border border-line overflow-hidden">
            {[{ key: "all", label: "All" }, ...SOURCES].map((s) => (
              <button key={s.key} onClick={() => setSource(s.key)}
                className={`text-meta px-3 py-2 transition ${
                  source === s.key ? "bg-ink text-canvas font-medium" : "bg-card text-muted hover:bg-canvas hover:text-ink"
                }`}>
                {s.label}
              </button>
            ))}
          </div>
          {filtered && (
            <button className="lnk text-meta" onClick={() => { setSource("all"); setQ(""); }}>Clear</button>
          )}
          <span className="ml-auto text-muted text-meta tabular-nums">{view.length} of {rows.length}</span>
        </div>

        {!d ? (
          <Empty action="Reading the log…">Loading</Empty>
        ) : view.length ? (
          <Table>
            <thead>
              <tr>
                <Th>When</Th>
                <Th>Source</Th>
                <Th>What failed</Th>
                <Th>Message</Th>
                <Th>Subject</Th>
                <Th>Version</Th>
              </tr>
            </thead>
            <tbody>
              {view.map((r) => (
                <tr key={r.id}
                    onClick={() => setOpen(open === r.id ? null : r.id)}
                    className={r.detail ? "cursor-pointer" : ""}>
                  <Td className="text-muted whitespace-nowrap">{when(r.at)}</Td>
                  <Td><Pill tone={toneOf(r.source) as any}>{r.source}</Pill></Td>
                  <Td className="font-medium whitespace-nowrap">{r.kind}</Td>
                  <Td className="text-muted">
                    {r.message}
                    {/* The stack is the point of a log, but it cannot sit in a
                        table cell — expand it in place instead. */}
                    {r.detail && open === r.id && (
                      <pre className="mt-2 p-3 panel text-meta font-mono whitespace-pre-wrap break-all max-h-64 overflow-auto">
                        {r.detail}
                      </pre>
                    )}
                    {r.detail && open !== r.id && (
                      <span className="ml-2 text-faint text-meta">· click for detail</span>
                    )}
                  </Td>
                  <Td className="font-mono text-meta text-muted">{r.subject || "—"}</Td>
                  <Td className="text-muted text-meta">{r.version || "—"}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        ) : filtered ? (
          <Empty action={<button className="lnk" onClick={() => { setSource("all"); setQ(""); }}>Clear the filters</button>}>
            Nothing matches
          </Empty>
        ) : (
          <Empty action="Nothing has failed on record. App crashes appear here once a handset runs a build carrying the reporter.">
            No errors
          </Empty>
        )}

        {d?.notes?.length ? (
          <p className="text-faint text-meta mt-3">Sources unavailable: {d.notes.join("; ")}</p>
        ) : null}
      </Card>
    </>
  );
}
