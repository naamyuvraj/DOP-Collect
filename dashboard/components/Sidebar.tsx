"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";

const NAV = [
  { href: "/", label: "Overview", icon: "M3 12l9-9 9 9M5 10v10h14V10" },
  { href: "/assistant", label: "Assistant", icon: "M12 3a9 9 0 00-9 9 9 9 0 001.5 5L3 21l4-1.5A9 9 0 1012 3zM8 12h.01M12 12h.01M16 12h.01" },
  { href: "/devices", label: "Users", icon: "M4 20a8 8 0 0116 0M12 12a4 4 0 100-8 4 4 0 000 8" },
  { href: "/regions", label: "Regions", icon: "M12 21s-7-6.5-7-11a7 7 0 0114 0c0 4.5-7 11-7 11zM12 12a2 2 0 100-4 2 2 0 000 4" },
  { href: "/activity", label: "Activity", icon: "M3 12h4l3 8 4-16 3 8h4" },
  { href: "/board", label: "Board", icon: "M4 4h16v16H4zM4 9h16M9 9v11" },
  { href: "/errors", label: "Errors", icon: "M12 9v4m0 4h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" },
  { href: "/keys", label: "API Keys", icon: "M15 7a4 4 0 11-4 4h-1l-2 2-2-2H3v-3l6-6a4 4 0 016 5z" },
  { href: "/otp", label: "OTP & MSG91", icon: "M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2zM9 10h.01M13 10h.01" },
  { href: "/payments", label: "Payments", icon: "M3 7h18v10H3zM3 11h18" },
  { href: "/plans", label: "Plans", icon: "M4 7h16v12H4zM4 7l2-3h12l2 3M9 12h6" },
  { href: "/releases", label: "Releases", icon: "M12 3v12m0 0l-4-4m4 4l4-4M4 17v2a2 2 0 002 2h12a2 2 0 002-2v-2" },
  { href: "/config", label: "App Config", icon: "M12 15a3 3 0 100-6 3 3 0 000 6zM4 12h2m12 0h2M12 4v2m0 12v2" },
];

export default function Sidebar() {
  const path = usePathname();
  const router = useRouter();
  const [open, setOpen] = useState(false);

  // Close on navigation. Without this the drawer stays over the page you just
  // asked for, which reads as the tap having failed.
  useEffect(() => { setOpen(false); }, [path]);

  async function logout() {
    await fetch("/api/auth", { method: "DELETE" });
    router.replace("/login");
  }

  return (
    <>
      {/* Mobile bar. The sidebar is a fixed 236px column, which simply does not
          fit a phone, so below lg it becomes a drawer behind this. */}
      <div className="lg:hidden fixed top-0 inset-x-0 z-40 h-14 bg-card border-b border-line flex items-center gap-3 px-4">
        <button
          onClick={() => setOpen((v) => !v)}
          aria-label={open ? "Close menu" : "Open menu"}
          aria-expanded={open}
          className="grid place-items-center w-9 h-9 -ml-1 rounded-[4px] hover:bg-canvas transition-colors"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"
               strokeWidth="2" strokeLinecap="round">
            {open ? <path d="M6 6l12 12M18 6L6 18" /> : <path d="M3 6h18M3 12h18M3 18h18" />}
          </svg>
        </button>
        <img src="/logo.png" alt="" width={44} height={44} className="w-11 h-11 rounded-[6px] object-contain" />
        <span className="font-display text-base font-medium tracking-[-0.015em]">DOP Collect</span>
      </div>

      {/* Scrim. Tapping away is the gesture everyone tries first. */}
      {open && (
        <div className="lg:hidden fixed inset-0 z-40 bg-ink/40" onClick={() => setOpen(false)} aria-hidden />
      )}

      <aside
        className={`w-[236px] shrink-0 bg-card border-r border-line h-screen flex flex-col
          fixed inset-y-0 left-0 z-50 transition-transform duration-200
          lg:static lg:translate-x-0
          ${open ? "translate-x-0" : "-translate-x-full"}`}
      >
      <div className="flex items-center gap-3 px-4 py-5 shrink-0">
        {/* The real app icon. This was a "₹" glyph in a tinted box — a
            placeholder that made the admin panel look unrelated to the app it
            administers. Sized 36px at 2x from a 128px source so it stays crisp
            on a retina display without shipping the 917KB original. */}
        <img src="/logo.png" alt="" width={56} height={56}
             className="w-14 h-14 rounded-[7px] object-contain shrink-0" />
        <div className="leading-tight">
          <div className="font-display text-base font-medium tracking-[-0.015em]">DOP Collect</div>
          <div className="text-faint text-micro mt-0.5">Admin</div>
        </div>
      </div>
      <nav className="flex-1 min-h-0 overflow-y-auto px-3 py-1 flex flex-col gap-0.5">
        {NAV.map((n) => {
          const active = n.href === "/" ? path === "/" : path.startsWith(n.href);
          return (
            <Link
              key={n.href}
              href={n.href}
              className={`group relative flex items-center gap-2.5 py-2 pl-4 pr-3 text-body transition-colors ${
                active ? "text-ink font-medium" : "text-muted hover:text-ink"
              }`}
            >
              {/* Hard-edged filled square in the accent marks where you are —
                  no pill, no rounding, no fill across the whole row. */}
              <span
                aria-hidden
                className={`absolute left-0 top-1/2 -translate-y-1/2 w-[3px] h-5 ${
                  active ? "bg-accent" : "bg-transparent"
                }`}
              />
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none"
                className="shrink-0"
                stroke="currentColor" strokeWidth="2" strokeLinecap="round"
                strokeLinejoin="round">
                <path d={n.icon} />
              </svg>
              {n.label}
            </Link>
          );
        })}
      </nav>
      <button
        onClick={logout}
        className="m-3 mt-auto shrink-0 px-4 py-2 text-body text-faint hover:text-ink transition-colors text-left"
      >
        Sign out
      </button>
      </aside>
    </>
  );
}
