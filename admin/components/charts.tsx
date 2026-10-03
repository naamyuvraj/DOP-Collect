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

const AXIS = { fontSize: 12, fill: "#6A727C", fontFamily: "inherit" };
const tip = {
  // Charcoal block, square corners, no elevation — the tooltip is a structural
  // object like everything else here.
  contentStyle: {
    borderRadius: 4,
    background: "#171C22",
    border: "none",
    color: "#F8F9FB",
    fontSize: 13,
    fontFamily: "inherit",
  },
  labelStyle: { color: "#B6BDC6", fontSize: 12, marginBottom: 3 },
  itemStyle: { color: "#F8F9FB" },
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
  color = "#171C22",
  height = 220,
  depth = 7,
}: {
  data: any[];
  x: string;
  y: string;
  color?: string;
  height?: number;
  depth?: number;
}) {
  const id = `g-${y}`;
  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data} margin={{ top: 6, right: depth + 6, left: 0, bottom: 0 }}>
        <defs>
          <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.30} />
            <stop offset="100%" stopColor={color} stopOpacity={0.06} />
          </linearGradient>
          {/* Extrudes the FILLED REGION only — applied via CSS to
              .recharts-area-area, never to the stroke. Filtering the whole
              series duplicated the curve and drew a second line alongside it. */}
          <filter id={`x-${y}`} x="-20%" y="-20%" width="140%" height="140%">
            <feOffset in="SourceAlpha" dx={depth} dy={depth} result="off" />
            <feFlood floodColor={shade(color, -0.30)} result="tone" />
            <feComposite in="tone" in2="off" operator="in" result="face" />
            <feMerge>
              <feMergeNode in="face" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
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
          strokeWidth={3}
          fill={`url(#${id})`}
          className={`iso-area iso-${y}`}
          animationDuration={650}
          animationEasing="ease-out"
          activeDot={{ r: 5, strokeWidth: 2, stroke: "#fff", fill: "#EDF751" }}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}

export function Bars({
  data,
  x,
  y,
  color = "#171C22",
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
        <Tooltip {...tip} cursor={{ fill: "#F4F5F9" }} formatter={full} />
        {/* Capped, or a single day of data renders as a slab the width of the card. */}
        <Bar
          dataKey={y}
          fill={color}
          radius={[2, 2, 0, 0]}
          maxBarSize={horizontal ? 18 : 40}
          animationDuration={650}
          animationEasing="ease-out"
        />
      </BarChart>
    </ResponsiveContainer>
  );
}

// Accent first, then charcoal steps down. Three tones, no rainbow.
const DONUT = ["#EDF751", "#171C22", "#292C2F", "#6A727C", "#969CA5", "#C9CDD3"];

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
          innerRadius="62%"
          outerRadius="88%"
          paddingAngle={0}
          animationDuration={650}
          animationEasing="ease-out"
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

/* --- Isometric bars --------------------------------------------------------
   Recharts draws flat rects. Passing a custom `shape` lets us draw a real block
   — front face, top face, right face — while keeping the axes, tooltip and
   responsive container we already rely on.

   Geometry, for a bar at (x,y,w,h) with depth d:
     front  rect(x, y, w, h)
     top    (x,y) → (x+d, y-d) → (x+w+d, y-d) → (x+w, y)
     right  (x+w,y) → (x+w+d, y-d) → (x+w+d, y+h-d) → (x+w, y+h)
   The light rakes from the top-left, matching the extruded cards, so the top
   face lightens and the right face darkens. */

const clamp = (n: number) => Math.max(0, Math.min(255, Math.round(n)));
/** Shift a hex toward white (amt > 0) or black (amt < 0). */
function shade(hex: string, amt: number): string {
  const h = hex.replace("#", "");
  const n = parseInt(h.length === 3 ? h.split("").map((c) => c + c).join("") : h, 16);
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  const t = amt > 0 ? 255 : 0, p = Math.abs(amt);
  return `rgb(${clamp(r + (t - r) * p)}, ${clamp(g + (t - g) * p)}, ${clamp(b + (t - b) * p)})`;
}

type IsoProps = {
  x?: number; y?: number; width?: number; height?: number; fill?: string;
  depth?: number;
  /** Only the bottom segment of a stack draws the floor shadow. */
  base?: boolean;
};

function IsoBar({ x = 0, y = 0, width = 0, height = 0, fill = "#171C22", depth = 9, base }: IsoProps) {
  if (!(height > 0) || !(width > 0)) return null;
  const d = Math.min(depth, width * 0.45);
  const top = shade(fill, 0.22);
  const side = shade(fill, -0.26);
  return (
    <g>
      {/* Floor plane: the block's own footprint, thrown to the right and down.
          Sold the reference's "reflections on the floor plane" without a blur. */}
      {base && (
        <polygon
          points={`${x + d * 0.4},${y + height} ${x + d * 1.4},${y + height - d} ${x + width + d * 1.4},${y + height - d} ${x + width + d * 0.4},${y + height}`}
          fill="rgb(23 28 34)"
          opacity={0.07}
        />
      )}
      <polygon
        points={`${x + width},${y} ${x + width + d},${y - d} ${x + width + d},${y + height - d} ${x + width},${y + height}`}
        fill={side}
      />
      <polygon
        points={`${x},${y} ${x + d},${y - d} ${x + width + d},${y - d} ${x + width},${y}`}
        fill={top}
      />
      <rect x={x} y={y} width={width} height={height} fill={fill} />
    </g>
  );
}

export type Series = { key: string; color: string; label: string };

/**
 * Categorical ramp for one-bar-per-category charts. Stays inside the three-tone
 * system — accent, then charcoal stepping down through the greys — so eight
 * event types stay tellable apart without turning the panel into a rainbow.
 */
export const RAMP = [
  "#EDF751", "#171C22", "#3C434C", "#8A929C",
  "#C2C8CF", "#B8C72F", "#5A626C", "#E0E4E9",
];

/**
 * Isometric bar chart. One series draws a solid block; several stack into the
 * layered slabs the reference uses. Stacking is only honest when the series are
 * parts of one whole — do not reach for it to put unrelated numbers on one bar.
 */
export function Bars3D({
  data, x, series, height = 260, depth = 9, legend = true,
  horizontal = false, colorByPoint = false,
}: {
  data: any[]; x: string; series: Series[]; height?: number; depth?: number;
  legend?: boolean;
  /** Bars run left-to-right, categories down the axis. */
  horizontal?: boolean;
  /** One colour per category, from RAMP, instead of one per series. */
  colorByPoint?: boolean;
}) {
  const stacked = series.length > 1;
  const BAR = horizontal ? 26 : 42;
  /* Proportional, and halved: recharts applies barCategoryGap to BOTH sides of
     a band, so the value is roughly half the total space it takes. 15px
     measured as a 30px gap; "30%" left the bars thinner than the gaps. At 18%
     a 36px row gives a ~23px bar with ~13px clearance, which covers the 9px
     extrusion without the chart reading as mostly whitespace. */
  const gap = "18%";
  const ROW = 36;
  /**
   * A horizontal chart needs room per row for the bar AND its extrusion. Fixing
   * the height and widening the gap instead just squeezed the bars — 8 rows in
   * 260px went to 4px bars, and Activity's collapsed to nothing. Derive the
   * height from the data so each row always has its clearance.
   */
  const plotH = horizontal
    ? Math.max(height, data.length * ROW + depth + 26)
    : height;
  return (
    <div>
      <ResponsiveContainer width="100%" height={plotH}>
        {/* The top face is drawn ABOVE y and the end face to the RIGHT of x, so
            both need margin or they clip against the plot edge. */}
        <BarChart
          data={data}
          layout={horizontal ? "vertical" : "horizontal"}
          margin={{ top: depth + 8, right: depth + 12, left: 0, bottom: 0 }}
          /* The block is drawn `depth` px above and to the right of its own
             rect, so neighbours need at least that much clearance or the lit
             top face runs into the bar next door. Recharts' default 10% gap
             measured 6px against a 9px depth — hence the overlap. */
          barCategoryGap={gap}
        >
          {horizontal ? (
            <>
              <XAxis type="number" tick={AXIS} axisLine={false} tickLine={false} tickFormatter={compact} />
              <YAxis type="category" dataKey={x} tick={AXIS} axisLine={false} tickLine={false} width={104} />
            </>
          ) : (
            <>
              <XAxis dataKey={x} tick={AXIS} axisLine={false} tickLine={false} tickMargin={8} />
              <YAxis tick={AXIS} axisLine={false} tickLine={false} allowDecimals={false} width={44} tickFormatter={compact} />
            </>
          )}
          <Tooltip {...tip} cursor={{ fill: "#F4F5F9" }} formatter={full} />
          {series.map((sr, i) => (
            <Bar
              key={sr.key}
              dataKey={sr.key}
              name={sr.label}
              stackId={stacked ? "s" : undefined}
              fill={sr.color}
              maxBarSize={BAR}
              isAnimationActive={false}
              shape={<IsoBar depth={depth} base={i === 0} />}
            >
              {/* Cell fills flow into the custom shape as `fill`, so each block
                  gets its own lit top and shaded side automatically. */}
              {colorByPoint && !stacked &&
                data.map((_, j) => <Cell key={j} fill={RAMP[j % RAMP.length]} />)}
            </Bar>
          ))}
        </BarChart>
      </ResponsiveContainer>
      {legend && series.length > 1 && (
        <div className="flex flex-wrap items-center gap-x-5 gap-y-1.5 mt-3 pt-3 border-t border-line">
          {series.map((sr) => (
            <span key={sr.key} className="inline-flex items-center gap-2 text-meta text-muted">
              <span className="w-2.5 h-2.5 rounded-[1px]" style={{ background: sr.color }} />
              {sr.label}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}


/* --- Isometric donut -------------------------------------------------------
   Recharts' <Pie> draws flat sectors and gives no hook to change their
   geometry, so this is hand-drawn SVG. The ring is squashed on Y to project it
   into the same isometric plane as the bars, and each slice extrudes downward
   by `depth`.

   Painter's order does the hiding: every wall is drawn first, then the top ring
   over the top. Walls on the far side extrude down INTO the ring and get
   covered; walls on the near side extrude below it and stay visible. That is
   what makes it read as a solid object rather than two stacked rings. */

const TAU = Math.PI * 2;

/** Point on the projected ellipse at angle a (0 = 3 o'clock, clockwise). */
const pt = (cx: number, cy: number, rx: number, ry: number, a: number) =>
  [cx + rx * Math.cos(a), cy + ry * Math.sin(a)] as const;

/**
 * An SVG arc from a to a+2π has identical start and end points, so the renderer
 * draws NOTHING — a single-key donut vanished entirely. Any sweep wider than a
 * half turn is split in two, which also keeps the large-arc flag unambiguous.
 */
function arcSteps(a0: number, a1: number): [number, number][] {
  if (a1 - a0 <= Math.PI) return [[a0, a1]];
  const mid = (a0 + a1) / 2;
  return [[a0, mid], [mid, a1]];
}

function ringSlice(
  cx: number, cy: number, rx: number, ry: number, ir: number, a0: number, a1: number,
) {
  const big = 0;
  const steps = arcSteps(a0, a1);
  const [ox0, oy0] = pt(cx, cy, rx, ry, a0);
  let d = `M ${ox0} ${oy0}`;
  for (const [, b] of steps) {
    const [x, y] = pt(cx, cy, rx, ry, b);
    d += ` A ${rx} ${ry} 0 ${big} 1 ${x} ${y}`;
  }
  const [ix1, iy1] = pt(cx, cy, rx * ir, ry * ir, a1);
  d += ` L ${ix1} ${iy1}`;
  for (const [a] of [...steps].reverse()) {
    const [x, y] = pt(cx, cy, rx * ir, ry * ir, a);
    d += ` A ${rx * ir} ${ry * ir} 0 ${big} 0 ${x} ${y}`;
  }
  return d + " Z";
}

/** The outer band of a slice, extruded down by d. */
function outerWall(
  cx: number, cy: number, rx: number, ry: number, a0: number, a1: number, d: number,
) {
  const steps = arcSteps(a0, a1);
  const [x0, y0] = pt(cx, cy, rx, ry, a0);
  let p = `M ${x0} ${y0}`;
  for (const [, b] of steps) {
    const [x, y] = pt(cx, cy, rx, ry, b);
    p += ` A ${rx} ${ry} 0 0 1 ${x} ${y}`;
  }
  const [x1, y1] = pt(cx, cy, rx, ry, a1);
  p += ` L ${x1} ${y1 + d}`;
  for (const [a] of [...steps].reverse()) {
    const [x, y] = pt(cx, cy, rx, ry, a);
    p += ` A ${rx} ${ry} 0 0 0 ${x} ${y + d}`;
  }
  return p + " Z";
}

export function Donut3D({
  data, nameKey, valueKey, height = 220, depth = 18, squash = 0.58,
}: {
  data: any[]; nameKey: string; valueKey: string;
  height?: number; depth?: number; squash?: number;
}) {
  const rows = (data || []).filter((r) => Number(r?.[valueKey]) > 0);
  const total = rows.reduce((s, r) => s + Number(r[valueKey]), 0);
  if (!total) return <div style={{ height }} />;

  const W = 320;
  const cx = W / 2;
  const rx = Math.min(W, height / squash) * 0.34;
  const ry = rx * squash;
  const cy = height / 2 - depth / 2;

  // Start at the top so the first (largest) slice reads first.
  let a = -Math.PI / 2;
  const slices = rows.map((r, i) => {
    const frac = Number(r[valueKey]) / total;
    const seg = { a0: a, a1: a + frac * TAU, row: r, i, frac };
    a = seg.a1;
    return seg;
  });

  return (
    <div>
      <svg viewBox={`0 0 ${W} ${height}`} width="100%" height={height} role="img">
        {/* Floor plane, so the ring sits on something. */}
        <ellipse cx={cx} cy={cy + depth + ry * 0.06} rx={rx * 1.02} ry={ry * 1.02}
                 fill="rgb(23 28 34)" opacity={0.06} />
        {slices.map((s) => (
          <path key={`w${s.i}`}
                d={outerWall(cx, cy, rx, ry, s.a0, s.a1, depth)}
                fill={shade(DONUT[s.i % DONUT.length], -0.3)} />
        ))}
        {/* Redraw the top ring over the walls: the far-side wall extrudes down
            INTO the ring, and this is what buries it. */}
        {slices.map((s) => (
          <path key={`t${s.i}`}
                d={ringSlice(cx, cy, rx, ry, 0.62, s.a0, s.a1)}
                fill={DONUT[s.i % DONUT.length]}
                stroke="#fff" strokeWidth={1} />
        ))}
      </svg>
      <div className="flex flex-wrap items-center gap-x-5 gap-y-1.5 mt-2">
        {slices.map((s) => (
          <span key={s.i} className="inline-flex items-center gap-2 text-meta text-muted">
            <span className="w-2.5 h-2.5 rounded-[1px]"
                  style={{ background: DONUT[s.i % DONUT.length] }} />
            {String(s.row[nameKey])}
            <span className="text-faint tabular-nums">{Math.round(s.frac * 100)}%</span>
          </span>
        ))}
      </div>
    </div>
  );
}
