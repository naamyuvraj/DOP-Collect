"use client";

/**
 * The time window control, shared by every chart card.
 *
 * Was a row of six buttons in the card header, which crowded the title and had
 * nowhere to go on a phone. A select costs one line, reads its current value
 * without you decoding which chip is filled, and leaves room for windows a
 * button row could never fit.
 *
 * Native <select> on purpose: it is keyboard- and screen-reader-correct for
 * free, and on mobile it opens the platform picker rather than a cramped popover.
 */

export type Range = 1 | 2 | 7 | 14 | 30 | 90 | 0; // 0 = all time

export const RANGES: [Range, string][] = [
  [1, "Today"],
  [2, "Last 2 days"],
  [7, "Last 7 days"],
  [14, "Last 14 days"],
  [30, "Last 30 days"],
  [90, "Last 90 days"],
  [0, "All time"],
];

/**
 * Midnight, `range` days back, inclusive of today — so "Today" is today and
 * "Last 2 days" is today plus yesterday. Null means no lower bound.
 */
export function since(range: Range): number | null {
  if (!range) return null;
  const floor = new Date();
  floor.setHours(0, 0, 0, 0);
  floor.setDate(floor.getDate() - (range - 1));
  return floor.getTime();
}

/**
 * Windows are cut by DATE, never by row count: these series have no row for a
 * quiet day, so taking the last N rows would silently reach further back than
 * the label claims.
 */
export function withinRange<T>(rows: T[], at: (r: T) => string, range: Range): T[] {
  const floor = since(range);
  if (floor == null) return rows;
  return rows.filter((r) => new Date(at(r)).getTime() >= floor);
}

export default function RangeSelect({
  value,
  onChange,
  id,
}: {
  value: Range;
  onChange: (r: Range) => void;
  id?: string;
}) {
  return (
    <select
      id={id}
      aria-label="Time window"
      className="input w-auto text-meta py-1 pl-2 pr-7 cursor-pointer"
      value={String(value)}
      onChange={(e) => onChange(Number(e.target.value) as Range)}
    >
      {RANGES.map(([r, label]) => (
        <option key={r} value={r}>
          {label}
        </option>
      ))}
    </select>
  );
}
