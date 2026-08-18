import Sidebar from "@/components/Sidebar";
import { dbConfigured } from "@/lib/supabase";

export default function DashLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    // App shell: full viewport height, no page scroll. The sidebar stays frozen
    // and ONLY the <main> content area scrolls.
    <div className="flex h-screen overflow-hidden">
      <Sidebar />
      <main className="flex-1 min-w-0 h-screen overflow-y-auto">
        {!dbConfigured() && (
          <div className="bg-focal text-ink text-body font-medium px-8 py-2.5 sticky top-0 z-10">
            ⚠️ Supabase not configured — set SUPABASE_URL and
            SUPABASE_SERVICE_ROLE_KEY in <code>.env.local</code>.
          </div>
        )}
        <div className="max-w-[1240px] mx-auto px-8 py-8">{children}</div>
      </main>
    </div>
  );
}
