import { ReactNode } from "react";
import Link from "next/link";
import CountUp from "./CountUp";
import { Icon } from "./icons";

/** Literal names on purpose — a `card-${tone}` template hides them from
 *  Tailwind's content scanner, which then strips the rules. */
/** Surfaces. `accent` is the neon block — at most one per row, on the number
 *  that is actually moving. Everything else is a plain white card. */
const TONE = { accent: "card-accent" } as const;

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
  href,
  tone,
}: {
  label: string;
  value: ReactNode;
  sub?: string;
  focal?: boolean;
  wide?: boolean;
  minor?: boolean;
  icon?: string;
  /** Where this number lives in full. Makes the tile a link. */
  href?: string;
  /** Palette tint: g green, b blue, a amber. Omit for plain glass. */
  tone?: "accent";
}) {
  const pad = `${focal ? "p-5" : minor ? "p-4" : "p-[18px]"} ${wide ? "col-span-2" : ""}`;
  // Size and colour carry the hierarchy. Weight stays at 600 — 700 only for the
  // hero — because a panel where everything is 800 has no emphasis left to give.
  // Weight AND size separate the tiers, so the hero still leads once every
  // figure is heavier. 700 / 600 / 500 against 42 / 28 / 21 — two axes of
  // difference, which survives being read at a glance across a wide row.
  const size = focal
    ? "text-[42px] font-bold"
    : minor
      ? "text-[21px] font-medium"
      : "text-[28px] font-semibold";
  // A tile that names a metric should take you to it. The lift and the arrow are
  // there so you can tell which ones will, before you click.
  const cls = `card group relative block ${pad} ${
    focal ? "card-ink" : tone ? TONE[tone] : ""
  } ${href ? "hover:border-ink/40" : ""}`;

  const body = (
    <>
      {icon && (
        <span
          className={`absolute top-4 right-4 grid place-items-center ${
            focal ? "text-faint" : "text-faint"
          }`}
        >
          <Icon name={icon} />
        </span>
      )}
      {/* pr- clears the absolutely-positioned icon. Without it a long label
          ("Cost per verified agent") runs under the badge and is clipped. */}
      <div className={`lbl ${icon ? "pr-8" : ""}`}>
        {label}
      </div>
      <div className={`font-display ${size} leading-none tracking-[-0.03em] tabular-nums mt-3`}>
        {/* Only strings roll — a node value is passed straight through. */}
        {typeof value === "string" ? <CountUp>{value}</CountUp> : value}
      </div>
      {sub && (
        <div className="text-meta mt-2 text-muted">
          {sub}
        </div>
      )}
      {href && (
        <span
          aria-hidden
          className={`absolute bottom-3.5 right-3.5 text-body opacity-0 -translate-x-1
            transition duration-200 group-hover:opacity-100 group-hover:translate-x-0
            text-faint`}
        >
          &rarr;
        </span>
      )}
    </>
  );

  return href ? (
    <Link href={href} className={cls} data-tilt>
      {body}
    </Link>
  ) : (
    <div className={cls} data-tilt>{body}</div>
  );
}

export function Card({
  title,
  right,
  children,
  className = "",
  tone,
}: {
  title?: string;
  right?: ReactNode;
  children: ReactNode;
  className?: string;
  tone?: "accent";
}) {
  return (
    <div className={`card reveal p-5 ${tone ? TONE[tone] : ""} ${className}`}>
      {(title || right) && (
        <div className="flex items-center justify-between gap-3 mb-4">
          {title && (
            <h2 className="font-display text-base font-medium tracking-[-0.015em]">{title}</h2>
          )}
          {right}
        </div>
      )}
      {children}
    </div>
  );
}

/**
 * The one switch. Was copy-pasted into four pages, each with a white knob —
 * which on the neon accent track is about 1.2:1 and reads as "off" whichever
 * way it is set. The knob is charcoal when on, so the state is legible at a
 * glance, and the track carries the colour.
 */
export function Toggle({
  on,
  onChange,
  tone = "accent",
  label,
}: {
  on: boolean;
  onChange: (v: boolean) => void;
  tone?: "accent" | "red";
  label?: string;
}) {
  const track = on ? (tone === "red" ? "bg-red" : "bg-accent") : "bg-line";
  const knob = on && tone === "accent" ? "bg-ink" : "bg-card";
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      onClick={() => onChange(!on)}
      className={`relative shrink-0 w-12 h-7 rounded-full transition-colors ${track}
        focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ink/30`}
    >
      <span
        className={`absolute top-1 w-5 h-5 rounded-full transition-all duration-200 ${knob}
          ${on ? "left-6" : "left-1"}`}
        style={{ boxShadow: "0 1px 2px rgb(23 28 34 / .28)" }}
      />
    </button>
  );
}

export function Pill({ children, tone = "b" }: { children: ReactNode; tone?: "g" | "b" | "r" | "a" }) {
  // Dark-native: the old pale chips carried dark text, which is unreadable once
  // the card behind them went dark. A translucent wash of the hue with a light
  // foreground keeps the colour coding and the legibility.
  // Flat and square. Positive states take the accent fill with charcoal type
  // (14.7:1); everything else is a quiet grey so the neon stays meaningful.
  const map = {
    g: "bg-accent text-ink",
    b: "bg-canvas text-muted",
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
            className={`card ${hero ? "p-5 card-ink" : "p-[18px]"} ${
              hero && wide ? "col-span-2" : ""
            }`}
          >
            <Skel className={`h-2.5 w-14 ${hero ? "!bg-white/12" : ""}`} />
            <Skel
              className={`${hero ? "h-[34px] w-32 !bg-white/12" : "h-[24px] w-20"} mt-3`}
            />
          </div>
        );
      })}
    </div>
  );
}

/**
 * Four cubes chasing each other — the app's one loading indicator.
 *
 * Colour is inherited (`currentColor`), so it sits on a card or inside the ink
 * button without needing a light and a dark variant.
 */
export function Cubes({ className = "" }: { className?: string }) {
  return (
    <span className={`cubes ${className}`} role="status" aria-label="Loading">
      <i /><i /><i /><i />
    </span>
  );
}

/** Full-card "you are on your way in" state, shown while the route changes. */
export function Redirecting({ label = "Opening the dashboard" }: { label?: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-4 py-10">
      <Cubes />
      <span className="text-muted text-meta">{label}</span>
    </div>
  );
}
