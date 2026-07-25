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

const AXIS = { fontSize: 10, fill: "#95A69C", fontFamily: "inherit" };
const tip = {
  contentStyle: {
    borderRadius: 12,
    border: "1px solid #E3ECE5",
    fontSize: 12,
    fontFamily: "inherit",
  },
};

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
      <AreaChart data={data} margin={{ top: 6, right: 6, left: -18, bottom: 0 }}>
        <defs>
          <linearGradient id={`g-${y}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.25} />
            <stop offset="100%" stopColor={color} stopOpacity={0} />
          </linearGradient>
        </defs>
        <XAxis dataKey={x} tick={AXIS} axisLine={false} tickLine={false} />
        <YAxis tick={AXIS} axisLine={false} tickLine={false} allowDecimals={false} />
        <Tooltip {...tip} />
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
        margin={{ top: 6, right: 10, left: horizontal ? 30 : -18, bottom: 0 }}
      >
        {horizontal ? (
          <>
            <XAxis type="number" tick={AXIS} axisLine={false} tickLine={false} />
            <YAxis type="category" dataKey={x} tick={AXIS} axisLine={false} tickLine={false} width={90} />
          </>
        ) : (
          <>
            <XAxis dataKey={x} tick={AXIS} axisLine={false} tickLine={false} />
            <YAxis tick={AXIS} axisLine={false} tickLine={false} allowDecimals={false} />
          </>
        )}
        <Tooltip {...tip} cursor={{ fill: "#EEF3EF" }} />
        <Bar dataKey={y} fill={color} radius={[6, 6, 6, 6]} />
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
