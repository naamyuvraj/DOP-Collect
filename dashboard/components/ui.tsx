import { ReactNode } from "react";

export function Kpi({
  label,
  value,
  sub,
  focal,
}: {
  label: string;
  value: ReactNode;
  sub?: string;
  focal?: boolean;
}) {
  return (
    <div className={`card p-[18px] ${focal ? "!bg-focal" : ""}`}>
      <div className="lbl">{label}</div>
      <div className="text-[30px] font-extrabold leading-none mt-1.5">
        {value}
      </div>
      {sub && <div className="text-muted text-[13px] font-semibold mt-1">{sub}</div>}
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
