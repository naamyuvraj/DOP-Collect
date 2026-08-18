"use client";
import { useEffect } from "react";

/**
 * Cursor-tracking 3D tilt for anything marked `data-tilt`.
 *
 * Mounted once and delegated from the document rather than wrapping every card
 * in its own listener component: a wrapper would sit between the grid and the
 * card, and `col-span-2` / `.stagger > *` both target the direct child, so the
 * layout would quietly break. Writing CSS variables straight onto the card
 * keeps the DOM exactly as it was.
 *
 * Skipped entirely for reduced-motion and for coarse pointers — a tilt that
 * tracks a cursor is meaningless on a touchscreen and just costs battery.
 */
export default function TiltLayer({ max = 5 }: { max?: number }) {
  useEffect(() => {
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const coarse = window.matchMedia("(pointer: coarse)").matches;
    if (still || coarse) return;

    let raf = 0;
    let pending: { el: HTMLElement; x: number; y: number } | null = null;
    let active: HTMLElement | null = null;

    const apply = () => {
      raf = 0;
      if (!pending) return;
      const { el, x, y } = pending;
      const r = el.getBoundingClientRect();
      // -0.5..0.5 from the card's centre, so the far edge tips away from you.
      const px = (x - r.left) / r.width - 0.5;
      const py = (y - r.top) / r.height - 0.5;
      el.style.setProperty("--ry", `${(px * max).toFixed(2)}deg`);
      el.style.setProperty("--rx", `${(-py * max).toFixed(2)}deg`);
    };

    const reset = (el: HTMLElement) => {
      el.style.removeProperty("--rx");
      el.style.removeProperty("--ry");
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

    // Leaving the window entirely never fires a move over a non-card, so the
    // last card would stay frozen mid-tilt.
    const onLeaveWindow = () => {
      if (active) reset(active);
      active = null;
    };

    document.addEventListener("pointermove", onMove, { passive: true });
    document.addEventListener("pointerleave", onLeaveWindow);
    window.addEventListener("blur", onLeaveWindow);
    return () => {
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerleave", onLeaveWindow);
      window.removeEventListener("blur", onLeaveWindow);
      if (raf) cancelAnimationFrame(raf);
      if (active) reset(active);
    };
  }, [max]);

  return null;
}
