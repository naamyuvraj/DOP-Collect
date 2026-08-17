import { ReactNode } from "react";
import { Icon } from "./icons";

/**
 * Three deliberate weights. A row where every tile is the same size is a wall
 * of numbers with no answer in it — you read all six and still don't know what
 * the page is telling you.
 *
 *   focal   the one number the page is about. Wider (spans two grid columns),
 *           larger, tinted. At most one per row — that is the whole point.
 *   default the supporting figures that qualify the focal one.
 *   minor   counters you glance at. Present, not part of the story.
 *
 * `focal` carries its own `col-span-2`, so every grid holding one needs a
 * column more than it has tiles. Keeping the span here rather than at the call
 * site is what stops a second tile from quietly claiming the same weight.
 */
export function Kpi({
  label,
  value,
  sub,
  focal,
  minor,
  icon,
}: {
  label: string;
  value: ReactNode;
  sub?: string;
  focal?: boolean;
  minor?: boolean;
  icon?: string;
}) {
  const pad = focal ? "p-5 col-span-2" : minor ? "p-3.5" : "p-4";
  const size = focal ? "text-[34px]" : minor ? "text-[19px]" : "text-[25px]";
  return (
    <div
      className={`card relative transition hover:-translate-y-0.5 ${pad} ${
        focal ? "!bg-focal ring-1 ring-ink/[.07]" : ""
      }`}
    >
      {icon && (
        <span
          className={`absolute grid place-items-center rounded-full ${
            focal
              ? "top-4 right-4 w-8 h-8 bg-ink/10 text-ink"
              : "top-3 right-3 w-7 h-7 bg-canvas text-muted"
          }`}
        >
          <Icon name={icon} />
        </span>
      )}
      <div className={`lbl ${focal ? "!text-ink/60" : ""}`}>{label}</div>
      <div
        className={`${size} font-extrabold leading-none tracking-tight tabular-nums ${
          minor ? "mt-1.5" : "mt-2"
        }`}
      >
        {value}
      </div>
      {sub && (
        <div
          className={`font-semibold mt-1.5 ${
            focal ? "text-ink/60 text-[12.5px]" : "text-muted text-[12px]"
          }`}
        >
          {sub}
        </div>
      )}
    </div>
  );
}

export function Card({
  title,
  right,
  children,
  className = "",
}: {
  title?: string;
  right?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={`card p-[18px] ${className}`}>
      {(title || right) && (
        <div className="flex items-center justify-between mb-3">
          {title && <h2 className="font-extrabold text-[15px]">{title}</h2>}
          {right}
        </div>
      )}
      {children}
    </div>
  );
}

export function Pill({ children, tone = "b" }: { children: ReactNode; tone?: "g" | "b" | "r" | "a" }) {
  const map = {
    g: "bg-greenSoft text-green",
    b: "bg-blueSoft text-blue",
    r: "bg-redSoft text-red",
    a: "bg-focal text-amber",
  };
  return <span className={`pill ${map[tone]}`}>{children}</span>;
}

/**
 * Scrolling frame + table, so every table on the dashboard is the same table.
 * Wide ones scroll inside their own card rather than pushing the page sideways.
 */
export function Table({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div className="overflow-x-auto">
      <table className={`tbl ${className}`}>{children}</table>
    </div>
  );
}

/**
 * `num` is the alignment convention: numbers right-aligned and tabular, so
 * digits line up by place value down a column and a long figure is visibly
 * long. Text stays left. Pass it on the <Th> and the <Td> of the same column —
 * a right-aligned header over left-aligned cells is worse than neither.
 */
export function Th({ children, num }: { children?: ReactNode; num?: boolean }) {
  return (
    <th className={`lbl py-2 px-2 whitespace-nowrap ${num ? "text-right" : "text-left"}`}>
      {children}
    </th>
  );
}
export function Td({
  children,
  num,
  className = "",
}: {
  children: ReactNode;
  num?: boolean;
  className?: string;
}) {
  return (
    <td
      className={`py-2.5 px-2 border-t border-line ${
        num ? "text-right tabular-nums" : ""
      } ${className}`}
    >
      {children}
    </td>
  );
}

/**
 * What is missing, then what to do about it. The second line is the point:
 * an empty state that only describes the mechanism leaves you to work out the
 * next move yourself, and there is always a next move.
 */
export function Empty({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="py-10 px-4 text-center">
      <div className="text-[13.5px] font-bold text-ink">{children}</div>
      {action && <div className="text-muted text-[13px] mt-1.5">{action}</div>}
    </div>
  );
}

/** A shimmering placeholder block, sized by className, for loading states. */
export function Skel({ className = "" }: { className?: string }) {
  return <div className={`animate-pulse rounded-lg bg-line/70 ${className}`} />;
}

/**
 * A row of KPI-card skeletons while data loads. Pass the *same* grid classes
 * the real row uses, and `focal` if it leads with a hero tile — otherwise the
 * tiles jump sideways the moment the fetch lands.
 */
export function KpiSkeletons({
  n = 4,
  grid = "grid-cols-2 md:grid-cols-4",
  focal,
}: {
  n?: number;
  grid?: string;
  focal?: boolean;
}) {
  return (
    <div className={`grid gap-3.5 ${grid}`}>
      {Array.from({ length: n }).map((_, i) => {
        const hero = focal && i === 0;
        return (
          <div key={i} className={`card ${hero ? "p-5 col-span-2 !bg-focal/40" : "p-[18px]"}`}>
            <Skel className="h-2.5 w-14" />
            <Skel className={hero ? "h-9 w-28 mt-3.5" : "h-7 w-20 mt-3"} />
          </div>
        );
      })}
    </div>
  );
}
