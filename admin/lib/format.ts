export const inr = (n: number | null | undefined) =>
  "₹" + Math.round(Number(n) || 0).toLocaleString("en-IN");

export const num = (n: number | null | undefined) =>
  (Number(n) || 0).toLocaleString("en-IN");

export const when = (t: string | Date) =>
  new Date(t).toLocaleString("en-IN", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });

export const day = (t: string | Date) =>
  new Date(t).toLocaleDateString("en-IN", { day: "2-digit", month: "short" });

export const shortId = (s?: string | null) => (s ? s.slice(0, 8) : "—");
