import { ReactNode } from "react";
import { Icon } from "./icons";

/**
 * Three deliberate weights. A row where every tile is the same size is a wall
 * of numbers with no answer in it — you read all six and still don't know what
 * the page is telling you.
 *
 *   focal   the one number the page is about. Larger, and inverted to the
 *           sidebar's ink. At most one per row — that is the whole point. It
 *           was a saturated yellow fill, which read as a highlighter stripe
 *           rather than as emphasis.
 *   default the supporting figures that qualify the focal one.
 *   minor   counters you glance at. Present, not part of the story.
 *
 * `wide` adds the `col-span-2`, and a grid using it needs one column more than
 * it has tiles. Reserve it for a long value: a rupee total earns the width,
 * whereas a single digit stranded in a double-width tile just looks broken.
 */
export function Kpi({
  label,
  value,
  sub,
  focal,
  wide,
  minor,
  icon,
}: {
  label: string;
  value: ReactNode;
  sub?: string;
  focal?: boolean;
  wide?: boolean;
  minor?: boolean;
  icon?: string;
}) {
  const pad = `${focal ? "p-5" : minor ? "p-4" : "p-[18px]"} ${wide ? "col-span-2" : ""}`;
  // Size and colour carry the hierarchy. Weight stays at 600 — 700 only for the
  // hero — because a panel where everything is 800 has no emphasis left to give.
  const size = focal
    ? "text-[30px] font-bold"
    : minor
      ? "text-[17px] font-semibold"
      : "text-[22px] font-semibold";
  return (
    <div
      className={`card relative transition-shadow hover:shadow-elevHover ${pad} ${
        focal ? "!bg-ink !border-ink text-white" : ""
      }`}
    >
      {icon && (
        <span
          className={`absolute grid place-items-center rounded-lg ${
            focal
              ? "top-4 right-4 w-7 h-7 bg-white/10 text-white/60"
              : "top-3.5 right-3.5 w-6 h-6 bg-canvas text-faint"
          }`}
        >
          <Icon name={icon} />
        </span>
      )}
      {/* pr- clears the absolutely-positioned icon. Without it a long label
          ("Cost per verified agent") runs under the badge and is clipped. */}
      <div className={`lbl ${icon ? "pr-8" : ""} ${focal ? "!text-white/45" : ""}`}>
        {label}
      </div>
      <div className={`${size} leading-none tracking-[-0.02em] tabular-nums mt-2.5`}>
        {value}
      </div>
      {sub && (
        <div className={`text-meta mt-2 ${focal ? "text-white/50" : "text-muted"}`}>
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
    <div className={`card p-5 ${className}`}>
      {(title || right) && (
        <div className="flex items-center justify-between gap-3 mb-4">
          {title && (
            <h2 className="text-base font-semibold tracking-[-0.01em]">{title}</h2>
          )}
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
    a: "bg-amberSoft text-amber",
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
// first/last lose their side padding so a table sits flush with the card's own
// content edge rather than inside an inset box of its own.
export function Th({ children, num }: { children?: ReactNode; num?: boolean }) {
  return (
    <th
      className={`thd font-medium pb-2.5 px-3 first:pl-0 last:pr-0 whitespace-nowrap ${
        num ? "text-right" : "text-left"
      }`}
    >
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
      className={`py-3 px-3 first:pl-0 last:pr-0 border-t border-line ${
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
    <div className="py-12 px-4 text-center">
      <div className="text-body font-semibold text-ink">{children}</div>
      {action && (
        <div className="text-body text-muted mt-1.5 max-w-md mx-auto leading-relaxed">
          {action}
        </div>
      )}
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
  wide,
}: {
  n?: number;
  grid?: string;
  focal?: boolean;
  wide?: boolean;
}) {
  return (
    <div className={`grid gap-4 ${grid}`}>
      {Array.from({ length: n }).map((_, i) => {
        const hero = focal && i === 0;
        return (
          <div
            key={i}
            className={`card ${hero ? "p-5 !bg-ink !border-ink" : "p-[18px]"} ${
              hero && wide ? "col-span-2" : ""
            }`}
          >
            <Skel className={`h-2.5 w-14 ${hero ? "!bg-white/15" : ""}`} />
            <Skel
              className={`${hero ? "h-[30px] w-28 !bg-white/15" : "h-[22px] w-20"} mt-2.5`}
            />
          </div>
        );
      })}
    </div>
  );
}
