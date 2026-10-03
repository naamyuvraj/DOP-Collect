"use client";
import { useMemo } from "react";
import { Card, Empty } from "@/components/ui";
import { Bars3D, TrendArea, type SeriesSpec } from "@/components/LazyCharts";
import { usePersisted } from "@/lib/uiState";
import { day as dayLabel } from "@/lib/format";
import RangeSelect, { withinRange, type Range } from "@/components/RangeSelect";

/**
 * A time-series card with its own window.
 *
 * Filtering happens client-side over the series already fetched: these are one
 * row per day, so even a year is a few hundred rows — round-tripping the server
 * per button press would be slower and buy nothing.
 *
 * Windows are cut by DATE, not by row count. A quiet day produces no row in
 * these views, so slice(-7) would silently reach back further than a week and
 * quietly mislabel the axis.
 */
export default function TimeChart({
  title,
  data,
  dateKey = "day",
  series,
  kind = "area",
  storageKey,
  height = 220,
  legend,
  empty,
  right,
}: {
  title: string;
  data: any[];
  dateKey?: string;
  series: SeriesSpec[];
  kind?: "area" | "bars";
  storageKey: string;
  height?: number;
  legend?: boolean;
  empty?: React.ReactNode;
  right?: React.ReactNode;
}) {
  const [range, setRange] = usePersisted<Range>(`chart.${storageKey}`, 30);

  const view = useMemo(
    () => withinRange(data, (r) => r[dateKey], range),
    [data, dateKey, range]
  );

  const shown = useMemo(
    () => view.map((r) => ({ ...r, _label: dayLabel(r[dateKey]) })),
    [view, dateKey]
  );

  const hasValue = shown.some((r) => series.some((s) => Number(r[s.key]) > 0));

  return (
    <Card
      title={title}
      right={
        <div className="flex items-center gap-2">
          {right}
          <RangeSelect value={range} onChange={setRange} />
        </div>
      }
    >
      {hasValue ? (
        kind === "area" ? (
          <TrendArea data={shown} x="_label" y={series[0].key} color={series[0].color} height={height} />
        ) : (
          <Bars3D data={shown} x="_label" series={series} height={height} legend={legend} />
        )
      ) : (
        <Empty action={range ? "Try a wider window." : undefined}>
          {empty ?? "Nothing in this window"}
        </Empty>
      )}
    </Card>
  );
}
