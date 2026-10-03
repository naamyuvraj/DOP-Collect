"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import PageHead from "@/components/PageHead";
import { Skel } from "@/components/ui";
import type { Note } from "@/app/api/board/route";

const COLORS: { key: Note["color"]; swatch: string; face: string; text: string }[] = [
  { key: "yellow", swatch: "#EDF751", face: "bg-accent", text: "text-ink" },
  { key: "white", swatch: "#FFFFFF", face: "bg-card", text: "text-ink" },
  { key: "ink", swatch: "#171C22", face: "bg-ink", text: "text-card" },
];
const faceOf = (c: Note["color"]) => COLORS.find((x) => x.key === c) ?? COLORS[0];

/** Degrees either way. Enough to look pinned by hand, not enough to annoy. */
const MAX_TILT = 2.4;

const W = 232;   // note width — also the grid step when auto-placing
const H = 176;

/**
 * Each sheet's resting angle, derived from its id so it never changes between
 * renders. Random-per-render would make every note twitch on each keystroke,
 * and pinning something perfectly straight is the one thing that stops a board
 * of notes reading as paper.
 */
function tiltOf(id: string): number {
  // FNV-1a, then murmur3's final avalanche. The previous h*31+c had almost no
  // mixing, so ids differing by one character produced near-identical angles —
  // "t1" and "t2" both landed at about -3.2deg, and notes added in the same
  // second all leaned the same way. The avalanche is what makes one character
  // change the whole output.
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  h ^= h >>> 16; h = Math.imul(h, 2246822507);
  h ^= h >>> 13; h = Math.imul(h, 3266489909);
  h ^= h >>> 16;
  const u = (h >>> 0) / 4294967295;        // 0..1, well spread
  return Math.round((u * 2 - 1) * MAX_TILT * 100) / 100;  // symmetric about 0
}

export default function Board() {
  const [notes, setNotes] = useState<Note[] | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const surface = useRef<HTMLDivElement>(null);
  // Drag state lives in a ref: a state update per mousemove would re-render the
  // whole board 60 times a second and the note would visibly lag the cursor.
  const drag = useRef<{ id: string; dx: number; dy: number } | null>(null);
  const [lifted, setLifted] = useState<string | null>(null);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    fetch("/api/board", { cache: "no-store" })
      .then((r) => r.json())
      .then((d) => { latest.current = d.notes || []; setNotes(d.notes || []); })
      .catch(() => setNotes([]));
  }, []);

  // Mirrors state for the debounced save, which fires after the closure that
  // scheduled it has gone stale.
  const latest = useRef<Note[]>([]);

  /**
   * Every mutation goes through an UPDATER, never a precomputed array.
   *
   * Taking `notes` from the render closure meant two handlers firing from
   * different renders would each write their own snapshot — dropping a note's
   * text if you typed and then dragged, because the drag's patch still held the
   * pre-typing array. Cost a note during testing. Functional updates always see
   * the current value, so writes compose instead of clobbering.
   *
   * Debounced because dragging would otherwise PUT on every pixel.
   */
  const persist = useCallback((updater: (prev: Note[]) => Note[]) => {
    setNotes((prev) => {
      const next = updater(prev || []);
      latest.current = next;
      return next;
    });
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      fetch("/api/board", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notes: latest.current }),
      });
    }, 500);
  }, []);

  const patch = (id: string, p: Partial<Note>) =>
    persist((prev) =>
      prev.map((n) => (n.id === id ? { ...n, ...p, updated_at: new Date().toISOString() } : n))
    );

  function add() {
    const list = notes || [];
    // Lay new notes out on a grid so they never land exactly on top of each
    // other — an invisible stack reads as "Add did nothing".
    const i = list.length;
    const cols = Math.max(1, Math.floor(((surface.current?.clientWidth ?? 900) - 24) / (W + 16)));
    const note: Note = {
      id: `n${Date.now().toString(36)}`,
      text: "",
      color: "yellow",
      x: 12 + (i % cols) * (W + 16),
      y: 12 + Math.floor(i / cols) * (H + 16),
    };
    persist((prev) => [...prev, note]);
    setEditing(note.id);
  }

  const remove = (id: string) => persist((prev) => prev.filter((n) => n.id !== id));

  function onDown(e: React.PointerEvent, n: Note) {
    if (n.pinned || editing === n.id) return;         // pinned notes stay put
    if ((e.target as HTMLElement).closest("button,textarea")) return;
    const r = surface.current!.getBoundingClientRect();
    drag.current = { id: n.id, dx: e.clientX - r.left - n.x, dy: e.clientY - r.top - n.y };
    setLifted(n.id);
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }
  function onMove(e: React.PointerEvent) {
    const d = drag.current;
    if (!d) return;
    const r = surface.current!.getBoundingClientRect();
    const el = document.getElementById(`note-${d.id}`);
    if (!el) return;
    const x = Math.max(0, Math.min(r.width - W, e.clientX - r.left - d.dx));
    const y = Math.max(0, e.clientY - r.top - d.dy);
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
  }
  function onUp() {
    const d = drag.current;
    drag.current = null;
    setLifted(null);
    if (!d) return;
    const el = document.getElementById(`note-${d.id}`);
    if (el) patch(d.id, { x: parseFloat(el.style.left), y: parseFloat(el.style.top) });
  }

  const open = (notes || []).filter((n) => !n.done).length;

  return (
    <>
      <PageHead
        title="Board"
        subtitle="Notes, reminders and what's next — drag them anywhere"
        right={
          <div className="flex items-center gap-3">
            {notes && <span className="text-muted text-meta tabular-nums">{open} open</span>}
            <button className="btn btn-accent" onClick={add}>+ Add note</button>
          </div>
        }
      />

      {!notes ? (
        <div className="grid gap-4 grid-cols-2 md:grid-cols-4">
          {[0, 1, 2, 3].map((i) => <Skel key={i} className="h-[176px] w-full" />)}
        </div>
      ) : (
        <div
          ref={surface}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onPointerCancel={onUp}
          className="relative rounded-[4px] border border-line bg-canvas overflow-hidden"
          style={{
            minHeight: 560,
            // Faint pin-board grid, drawn rather than imaged so it costs nothing.
            backgroundImage:
              "radial-gradient(rgb(23 28 34 / .07) 1px, transparent 1px)",
            backgroundSize: "22px 22px",
          }}
        >
          {!notes.length && (
            <div className="absolute inset-0 grid place-items-center text-center px-6">
              <div>
                <div className="text-body font-semibold">The board is empty</div>
                <div className="text-muted text-body mt-1.5">
                  Add a note for anything that needs doing — it saves as you type.
                </div>
              </div>
            </div>
          )}

          {notes.map((n) => {
            const f = faceOf(n.color);
            return (
              <div
                key={n.id}
                id={`note-${n.id}`}
                onPointerDown={(e) => onDown(e, n)}
                style={{ left: n.x, top: n.y, width: W, minHeight: H, ["--rot" as any]: `${tiltOf(n.id)}deg` }}
                className={`note-paper absolute select-none ${f.face} ${f.text}
                  ${n.color === "ink" ? "note-ink" : ""}
                  ${lifted === n.id ? "note-lift" : ""}
                  ${n.pinned ? "cursor-default" : "cursor-grab"}
                  ${n.done ? "opacity-60" : ""}`}
              >
                {/* Surface lighting, held behind the content. */}
                <span className="note-grain absolute inset-0 pointer-events-none" aria-hidden />
                <span className="note-fold" aria-hidden />
                {n.pinned && <span className="note-pin" aria-hidden />}
                <div className="relative p-3">
                <div className="flex items-center gap-1 mb-2">
                  {/* The pin. Filled = fixed in place. */}
                  <button
                    title={n.pinned ? "Unpin" : "Pin in place"}
                    onClick={() => patch(n.id, { pinned: !n.pinned })}
                    className="w-6 h-6 grid place-items-center rounded-[3px] hover:bg-ink/10 transition-colors"
                  >
                    <span className={`block w-2.5 h-2.5 rounded-full ${n.pinned ? "bg-red" : "border-2 border-current opacity-45"}`} />
                  </button>
                  <button
                    title={n.done ? "Mark as open" : "Mark as done"}
                    onClick={() => patch(n.id, { done: !n.done })}
                    className="w-6 h-6 grid place-items-center rounded-[3px] hover:bg-ink/10 transition-colors text-meta font-semibold"
                  >
                    {n.done ? "✓" : "○"}
                  </button>
                  <div className="ml-auto flex items-center gap-1">
                    {COLORS.map((c) => (
                      <button
                        key={c.key}
                        title={c.key}
                        onClick={() => patch(n.id, { color: c.key })}
                        className={`w-3.5 h-3.5 rounded-[2px] border ${n.color === c.key ? "border-current" : "border-black/15"}`}
                        style={{ background: c.swatch }}
                      />
                    ))}
                    <button
                      title="Delete"
                      onClick={() => remove(n.id)}
                      className="w-6 h-6 grid place-items-center rounded-[3px] hover:bg-red/20 transition-colors text-meta"
                    >
                      ✕
                    </button>
                  </div>
                </div>
                <textarea
                  value={n.text}
                  placeholder="Write something…"
                  onFocus={() => setEditing(n.id)}
                  onBlur={() => setEditing(null)}
                  onChange={(e) => patch(n.id, { text: e.target.value })}
                  className={`w-full bg-transparent border-0 outline-none resize-none text-body leading-snug
                    placeholder:opacity-45 ${n.done ? "line-through" : ""}`}
                  rows={4}
                />
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}
