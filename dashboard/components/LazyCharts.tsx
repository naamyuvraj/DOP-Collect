"use client";
// Recharts is ~100kB and the single biggest thing to compile (dev) and ship
// (prod) on the chart pages. Load it lazily and client-only so the page's KPIs,
// tables and layout render immediately and the charts stream in a beat later.
// The rest of the app never pays recharts' cost at all.
import dynamic from "next/dynamic";

function Skeleton() {
  return <div className="w-full h-[220px] animate-pulse rounded-xl bg-line/60" />;
}

// Prop shapes mirror components/charts.tsx.
type TrendAreaProps = { data: any[]; x: string; y: string; color?: string; height?: number };
type BarsProps = { data: any[]; x: string; y: string; color?: string; horizontal?: boolean; height?: number };
type DonutProps = { data: any[]; nameKey: string; valueKey: string; height?: number };

// NOTE: next/dynamic options must be an inline object literal (SWC requirement).
export const TrendArea = dynamic<TrendAreaProps>(
  () => import("./charts").then((m) => m.TrendArea),
  { ssr: false, loading: () => <Skeleton /> }
);
export const Bars = dynamic<BarsProps>(
  () => import("./charts").then((m) => m.Bars),
  { ssr: false, loading: () => <Skeleton /> }
);
export const Donut = dynamic<DonutProps>(
  () => import("./charts").then((m) => m.Donut),
  { ssr: false, loading: () => <Skeleton /> }
);
