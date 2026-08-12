import { ReactNode } from "react";
import { Icon } from "./icons";

export function Kpi({
  label,
  value,
  sub,
  focal,
  icon,
}: {
  label: string;
  value: ReactNode;
  sub?: string;
  focal?: boolean;
  icon?: string;
}) {
  return (
    <div className={`card p-4 relative transition hover:-translate-y-0.5 ${focal ? "!bg-focal" : ""}`}>
      {icon && (
        <span className={`absolute top-3 right-3 grid place-items-center w-7 h-7 rounded-full ${focal ? "bg-ink/10 text-ink" : "bg-canvas text-muted"}`}>
          <Icon name={icon} />
        </span>
      )}
      <div className="lbl">{label}</div>
      <div className="text-[26px] font-extrabold leading-none mt-2 tracking-tight">{value}</div>
      {sub && <div className="text-muted text-[12px] font-semibold mt-1.5">{sub}</div>}
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

export function Th({ children }: { children?: ReactNode }) {
  return (
    <th className="text-left lbl py-2 px-2 whitespace-nowrap">{children}</th>
  );
}
export function Td({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <td className={`py-2.5 px-2 border-t border-line ${className}`}>{children}</td>;
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="text-muted text-sm py-8 text-center">{children}</div>;
}

/** A shimmering placeholder block, sized by className, for loading states. */
export function Skel({ className = "" }: { className?: string }) {
  return <div className={`animate-pulse rounded-lg bg-line/70 ${className}`} />;
}

/** A row of KPI-card skeletons (matches the <Kpi> grid) while data loads. */
export function KpiSkeletons({ n = 4 }: { n?: number }) {
  return (
    <div className="grid gap-3.5 grid-cols-2 md:grid-cols-4">
      {Array.from({ length: n }).map((_, i) => (
        <div key={i} className="card p-[18px]">
          <Skel className="h-2.5 w-14" />
          <Skel className="h-7 w-20 mt-3" />
        </div>
      ))}
    </div>
  );
}
