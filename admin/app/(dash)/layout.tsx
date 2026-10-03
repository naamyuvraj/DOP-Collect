import Sidebar from "@/components/Sidebar";
import TiltLayer from "@/components/TiltLayer";
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
      <TiltLayer />
      <Sidebar />
      <main className="flex-1 min-w-0 h-screen overflow-y-auto">
        {!dbConfigured() && (
          <div className="bg-accent text-ink text-body font-medium px-4 lg:px-8 py-2.5 sticky top-14 lg:top-0 z-10">
            ⚠️ Supabase not configured — set SUPABASE_URL and
            SUPABASE_SERVICE_ROLE_KEY in <code>.env.local</code>.
          </div>
        )}
        <div className="max-w-[1240px] mx-auto px-4 sm:px-6 lg:px-8 pt-[72px] pb-10 lg:pt-8 lg:pb-8">{children}</div>
      </main>
    </div>
  );
}
