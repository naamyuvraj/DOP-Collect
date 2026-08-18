"use client";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

const AXIS = { fontSize: 11, fill: "#95A69C", fontFamily: "inherit" };
const tip = {
  contentStyle: {
    borderRadius: 10,
    border: "1px solid #E3ECE5",
    boxShadow: "0 6px 16px -6px rgba(16,27,18,.14)",
    fontSize: 12,
    fontFamily: "inherit",
  },
  labelStyle: { color: "#5B6B62", fontSize: 11, marginBottom: 2 },
};

/**
 * Lakh/crore, because the y-axis carries rupee figures and "1000000" is both
 * unreadable and too wide for the gutter — the axis used a -18px left margin to
 * claw back space, which simply clipped the wider labels off the card.
 */
const compact = (n: number) => {
  const a = Math.abs(n);
  if (a >= 1e7) return +(n / 1e7).toFixed(a % 1e7 ? 1 : 0) + "Cr";
  if (a >= 1e5) return +(n / 1e5).toFixed(a % 1e5 ? 1 : 0) + "L";
  if (a >= 1e3) return +(n / 1e3).toFixed(a % 1e3 ? 1 : 0) + "k";
  return String(n);
};

/** Full precision in the tooltip — the axis is for scale, the tooltip for value. */
const full = (v: unknown) => (typeof v === "number" ? v.toLocaleString("en-IN") : String(v));

export function TrendArea({
  data,
  x,
  y,
  color = "#21A06A",
  height = 220,
}: {
  data: any[];
  x: string;
  y: string;
  color?: string;
  height?: number;
}) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data} margin={{ top: 6, right: 6, left: 0, bottom: 0 }}>
        <defs>
          <linearGradient id={`g-${y}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.25} />
            <stop offset="100%" stopColor={color} stopOpacity={0} />
          </linearGradient>
        </defs>
        <XAxis dataKey={x} tick={AXIS} axisLine={false} tickLine={false} tickMargin={8} />
        <YAxis
          tick={AXIS}
          axisLine={false}
          tickLine={false}
          allowDecimals={false}
          width={44}
          tickFormatter={compact}
        />
        <Tooltip {...tip} formatter={full} />
        <Area
          type="monotone"
          dataKey={y}
          stroke={color}
          strokeWidth={2.5}
          fill={`url(#g-${y})`}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}

export function Bars({
  data,
  x,
  y,
  color = "#14201A",
  horizontal = false,
  height = 260,
}: {
  data: any[];
  x: string;
  y: string;
  color?: string;
  horizontal?: boolean;
  height?: number;
}) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart
        data={data}
        layout={horizontal ? "vertical" : "horizontal"}
        margin={{ top: 6, right: 10, left: 0, bottom: 0 }}
      >
        {horizontal ? (
          <>
            <XAxis type="number" tick={AXIS} axisLine={false} tickLine={false} tickFormatter={compact} />
            <YAxis type="category" dataKey={x} tick={AXIS} axisLine={false} tickLine={false} width={96} />
          </>
        ) : (
          <>
            <XAxis dataKey={x} tick={AXIS} axisLine={false} tickLine={false} tickMargin={8} />
            <YAxis
              tick={AXIS}
              axisLine={false}
              tickLine={false}
              allowDecimals={false}
              width={44}
              tickFormatter={compact}
            />
          </>
        )}
        <Tooltip {...tip} cursor={{ fill: "#EEF3EF" }} formatter={full} />
        {/* Capped, or a single day of data renders as a slab the width of the card. */}
        <Bar dataKey={y} fill={color} radius={[6, 6, 6, 6]} maxBarSize={horizontal ? 18 : 40} />
      </BarChart>
    </ResponsiveContainer>
  );
}

const DONUT = ["#21A06A", "#2E3A8C", "#E5A100", "#E15B5B", "#6D3BD6", "#14201A"];

export function Donut({
  data,
  nameKey,
  valueKey,
  height = 220,
}: {
  data: any[];
  nameKey: string;
  valueKey: string;
  height?: number;
}) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <PieChart>
        <Pie
          data={data}
          dataKey={valueKey}
          nameKey={nameKey}
          innerRadius="58%"
          outerRadius="88%"
          paddingAngle={2}
        >
          {data.map((_, i) => (
            <Cell key={i} fill={DONUT[i % DONUT.length]} />
          ))}
        </Pie>
        <Tooltip {...tip} />
      </PieChart>
    </ResponsiveContainer>
  );
}
