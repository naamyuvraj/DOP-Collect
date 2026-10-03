"use client";
import { useEffect } from "react";

/**
 * Cursor-tracking tilt for anything marked `data-tilt`.
 *
 * Delegated from the document rather than wrapping each card: a wrapper would
 * sit between the grid and the card, and `col-span-2` and `.stagger > *` both
 * target the direct child, so the layout would break.
 *
 * Writes only CSS variables. Every transform lives in one rule in globals.css,
 * so the tilt and the hover lift compose instead of overwriting each other —
 * which is what happens the moment a Tailwind `-translate-y` joins in.
 */
export default function TiltLayer({ max = 4 }: { max?: number }) {
  useEffect(() => {
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const coarse = window.matchMedia("(pointer: coarse)").matches;
    if (still || coarse) return;

    let raf = 0;
    let pending: { el: HTMLElement; x: number; y: number } | null = null;
    let active: HTMLElement | null = null;

    const reset = (el: HTMLElement) => {
      for (const p of ["--rx", "--ry", "--ex", "--ey"]) el.style.removeProperty(p);
    };

    // A tall element rotated a few degrees sweeps its own top edge far enough to
    // slide out from under the cursor. :hover then drops, the transform resets,
    // the cursor is over it again — and it oscillates. Reported as jitter at the
    // top of the Activity table. Small tiles never travel far enough to do it.
    const MAX_TILT_HEIGHT = 340;

    const apply = () => {
      raf = 0;
      if (!pending) return;
      const { el, x, y } = pending;
      const r = el.getBoundingClientRect();
      if (r.height > MAX_TILT_HEIGHT) { reset(el); return; }
      const px = (x - r.left) / r.width - 0.5;
      const py = (y - r.top) / r.height - 0.5;
      el.style.setProperty("--ry", `${(px * max).toFixed(2)}deg`);
      el.style.setProperty("--rx", `${(-py * max).toFixed(2)}deg`);
      // Light rakes from the top-left, so the extruded face falls opposite the
      // tilt. Without this the block reads as a flat sticker that happens to rotate.
      el.style.setProperty("--ex", `${(6 - px * 5).toFixed(1)}px`);
      el.style.setProperty("--ey", `${(6 - py * 5).toFixed(1)}px`);
    };

    const onMove = (e: PointerEvent) => {
      const el = (e.target as Element | null)?.closest?.<HTMLElement>("[data-tilt]") ?? null;
      if (el !== active) {
        if (active) reset(active);
        active = el;
      }
      if (!el) return;
      pending = { el, x: e.clientX, y: e.clientY };
      if (!raf) raf = requestAnimationFrame(apply);
    };

    // Leaving the window never fires a move over a non-card, so the last card
    // would stay frozen mid-tilt.
    const off = () => { if (active) reset(active); active = null; };

    document.addEventListener("pointermove", onMove, { passive: true });
    document.addEventListener("pointerleave", off);
    window.addEventListener("blur", off);
    return () => {
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerleave", off);
      window.removeEventListener("blur", off);
      if (raf) cancelAnimationFrame(raf);
      if (active) reset(active);
    };
  }, [max]);

  return null;
}
