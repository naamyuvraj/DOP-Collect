// Small line-icon set (24×24 stroke paths) for KPI chips + accents. Single
// `d` per name (multiple subpaths allowed). Rendered with currentColor so the
// parent controls the tint.
const PATHS: Record<string, string> = {
  agents: "M12 12a4 4 0 100-8 4 4 0 000 8M4 20a8 8 0 0116 0",
  verified: "M9 12l2 2 4-4M12 21a9 9 0 100-18 9 9 0 000 18z",
  active: "M3 12h4l3 8 4-16 3 8h4",
  accounts: "M6 3h11a1 1 0 011 1v16a1 1 0 01-1 1H6a2 2 0 01-2-2V5a2 2 0 012-2zM9 7h6M9 11h6",
  value: "M3 7.5A1.5 1.5 0 014.5 6H18a1 1 0 011 1v2m0 0h-3a2 2 0 100 4h3m0-4v6a1 1 0 01-1 1H4.5A1.5 1.5 0 013 15z",
  collected: "M4 21h16M5 21V10l7-5 7 5v11M9 21v-5h6v5",
  installs: "M7 3h10a1 1 0 011 1v16a1 1 0 01-1 1H7a1 1 0 01-1-1V4a1 1 0 011-1zM10 18h4",
  revenue: "M3 7h18v10H3zM3 11h18",
  subscribers: "M12 3l2.4 5 5.6.5-4.2 3.7 1.3 5.4L12 15.9 6.9 17.6l1.3-5.4L4 8.5 9.6 8z",
  ai: "M12 3a9 9 0 00-9 9 9 9 0 001.5 5L3 21l4-1.5A9 9 0 1012 3zM8 12h.01M12 12h.01M16 12h.01",
  keys: "M15 7a4 4 0 11-4 4h-1l-2 2-2-2H3v-3l6-6a4 4 0 016 5z",
  region: "M12 21s-7-6.5-7-11a7 7 0 0114 0c0 4.5-7 11-7 11zM12 12a2 2 0 100-4 2 2 0 000 4",
};

export type IconName = keyof typeof PATHS;

export function Icon({ name, size = 15 }: { name: string; size?: number }) {
  const d = PATHS[name];
  if (!d) return null;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d={d} />
    </svg>
  );
}
