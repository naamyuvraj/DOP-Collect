"use client";
import { useMemo } from "react";
import { Card, Empty } from "@/components/ui";
import { Bars3D, Donut3D } from "@/components/LazyCharts";
import { usePersisted } from "@/lib/uiState";
import RangeSelect, { withinRange, type Range } from "@/components/RangeSelect";

type Row = { at: string; key: string };

/**
 * A category breakdown that can still be windowed.
 *
 * v_events_by_type and v_key_usage are pre-aggregated with no date column, so
 * neither could honour a range at all — putting a range selector on them would
 * have been decoration over a number that never changed. These take the RAW
 * rows, which do carry created_at, and roll them up per window instead.
 */
export default function AggregateChart({
  title,
  rows,
  storageKey,
  kind = "bars",
  height = 260,
  labelOf,
  empty,
}: {
  title: string;
  rows: Row[];
  storageKey: string;
  kind?: "bars" | "donut";
  height?: number;
  labelOf?: (k: string) => string;
  empty?: string;
}) {
  const [range, setRange] = usePersisted<Range>(`chart.${storageKey}`, 30);

  const data = useMemo(() => {
    const rs = withinRange(rows, (r) => r.at, range);
    const c = new Map<string, number>();
    for (const r of rs) c.set(r.key, (c.get(r.key) ?? 0) + 1);
    return [...c.entries()]
      .map(([k, n]) => ({ name: labelOf ? labelOf(k) : k, n }))
      .sort((a, b) => b.n - a.n)
      .slice(0, 8);
  }, [rows, range, labelOf]);

  return (
    <Card
      title={title}
      right={<RangeSelect value={range} onChange={setRange} />}
    >
      {data.length ? (
        kind === "donut" ? (
          <Donut3D data={data} nameKey="name" valueKey="n" height={height} />
        ) : (
          <Bars3D data={data} x="name" horizontal colorByPoint height={height}
                  series={[{ key: "n", color: "#171C22", label: "Count" }]} />
        )
      ) : (
        <Empty action={range ? "Try a wider window." : undefined}>{empty ?? "Nothing in this window"}</Empty>
      )}
    </Card>
  );
}
