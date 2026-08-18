"use client";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";

const NAV = [
  { href: "/", label: "Overview", icon: "M3 12l9-9 9 9M5 10v10h14V10" },
  { href: "/assistant", label: "Assistant", icon: "M12 3a9 9 0 00-9 9 9 9 0 001.5 5L3 21l4-1.5A9 9 0 1012 3zM8 12h.01M12 12h.01M16 12h.01" },
  { href: "/devices", label: "Users", icon: "M4 20a8 8 0 0116 0M12 12a4 4 0 100-8 4 4 0 000 8" },
  { href: "/regions", label: "Regions", icon: "M12 21s-7-6.5-7-11a7 7 0 0114 0c0 4.5-7 11-7 11zM12 12a2 2 0 100-4 2 2 0 000 4" },
  { href: "/activity", label: "Activity", icon: "M3 12h4l3 8 4-16 3 8h4" },
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

  async function logout() {
    await fetch("/api/auth", { method: "DELETE" });
    router.replace("/login");
  }

  return (
    <aside className="w-[232px] shrink-0 bg-sidebar text-white h-screen flex flex-col">
      <div className="flex items-center gap-3 px-4 py-5 shrink-0">
        {/* The real app icon. This was a "₹" glyph in a tinted box — a
            placeholder that made the admin panel look unrelated to the app it
            administers. Sized 36px at 2x from a 128px source so it stays crisp
            on a retina display without shipping the 917KB original. */}
        <img src="/logo.png" alt="" width={36} height={36}
             className="w-8 h-8 rounded-lg object-cover shrink-0" />
        <div className="leading-tight">
          <div className="text-base font-semibold tracking-[-0.01em]">DOP Collect</div>
          <div className="text-white/45 text-micro mt-0.5">Admin</div>
        </div>
      </div>
      <nav className="flex-1 min-h-0 overflow-y-auto px-3 py-1 flex flex-col gap-0.5">
        {NAV.map((n) => {
          const active = n.href === "/" ? path === "/" : path.startsWith(n.href);
          return (
            <Link
              key={n.href}
              href={n.href}
              className={`flex items-center gap-2.5 px-3 py-2 rounded-lg text-body transition ${
                active
                  ? "bg-white text-ink font-semibold"
                  : "text-white/65 font-medium hover:bg-white/[.07] hover:text-white"
              }`}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none"
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
        className="m-3 shrink-0 px-3 py-2 rounded-lg text-body font-medium text-white/50 hover:bg-white/[.07] hover:text-white transition text-left"
      >
        Sign out
      </button>
    </aside>
  );
}
