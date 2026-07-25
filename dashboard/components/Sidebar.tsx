"use client";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";

const NAV = [
  { href: "/", label: "Overview", icon: "M3 12l9-9 9 9M5 10v10h14V10" },
  { href: "/devices", label: "Users & Devices", icon: "M4 20a8 8 0 0116 0M12 12a4 4 0 100-8 4 4 0 000 8" },
  { href: "/activity", label: "Activity", icon: "M3 12h4l3 8 4-16 3 8h4" },
  { href: "/keys", label: "API Keys", icon: "M15 7a4 4 0 11-4 4h-1l-2 2-2-2H3v-3l6-6a4 4 0 016 5z" },
  { href: "/payments", label: "Payments", icon: "M3 7h18v10H3zM3 11h18" },
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
    <aside className="w-[236px] shrink-0 bg-sidebar text-white min-h-screen sticky top-0 flex flex-col">
      <div className="flex items-center gap-3 px-5 py-5">
        <div className="w-9 h-9 rounded-xl bg-white/10 grid place-items-center font-extrabold">
          ₹
        </div>
        <div className="leading-tight">
          <div className="font-extrabold">DOP Collect</div>
          <div className="text-white/50 text-[11px]">Admin</div>
        </div>
      </div>
      <nav className="flex-1 px-3 py-2 flex flex-col gap-1">
        {NAV.map((n) => {
          const active = n.href === "/" ? path === "/" : path.startsWith(n.href);
          return (
            <Link
              key={n.href}
              href={n.href}
              className={`flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-semibold transition ${
                active ? "bg-white text-ink" : "text-white/70 hover:bg-white/10"
              }`}
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none"
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
        className="m-3 px-3 py-2.5 rounded-xl text-sm font-semibold text-white/70 hover:bg-white/10 text-left"
      >
        Sign out
      </button>
    </aside>
  );
}
