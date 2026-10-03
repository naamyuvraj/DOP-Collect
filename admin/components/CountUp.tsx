"use client";
import { useEffect, useRef, useState } from "react";

/**
 * Rolls a already-formatted figure up from zero.
 *
 * Takes the FORMATTED string ("₹49,86,400", "809", "₹0.52") rather than a raw
 * number, so no call site has to change and nothing has to know whether a tile
 * is rupees, a count or a rate. It splits off the prefix and suffix, animates
 * the numeric core, and regroups with the same en-IN separators — so the
 * lakh/crore grouping stays correct the whole way up rather than snapping into
 * place at the end.
 *
 * Anything it cannot parse is rendered untouched, so a tile showing "—" or
 * "2 of 5" is never mangled.
 */
export default function CountUp({
  children,
  ms = 850,
}: {
  children: string;
  ms?: number;
}) {
  const text = String(children ?? "");
  // prefix (₹, ~) · numeric core with separators · suffix (%, /agent)
  const m = text.match(/^([^\d-]*)(-?[\d,.]*\d)(.*)$/s);
  const target = m ? Number(m[2].replace(/,/g, "")) : NaN;
  const decimals = m && m[2].includes(".") ? (m[2].split(".")[1] || "").length : 0;
  const animatable = !!m && Number.isFinite(target) && Math.abs(target) >= 1;

  const [n, setN] = useState(animatable ? 0 : target);
  const done = useRef(false);

  useEffect(() => {
    if (!animatable || done.current) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setN(target);
      done.current = true;
      return;
    }
    let raf = 0;
    const t0 = performance.now();
    const tick = (t: number) => {
      const p = Math.min(1, (t - t0) / ms);
      // Ease-out cubic: most of the distance early, so it settles rather than
      // creeping — a linear count reads like the page is stuck loading.
      setN(target * (1 - Math.pow(1 - p, 3)));
      if (p < 1) raf = requestAnimationFrame(tick);
      else done.current = true;
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [animatable, target, ms]);

  if (!animatable) return <>{text}</>;
  const shown = n.toLocaleString("en-IN", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
  return (
    <span className="counting">
      {m![1]}
      {shown}
      {m![3]}
    </span>
  );
}
