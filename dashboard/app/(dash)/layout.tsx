import Sidebar from "@/components/Sidebar";
import { dbConfigured } from "@/lib/supabase";

export default function DashLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="flex">
      <Sidebar />
      <main className="flex-1 min-w-0">
        {!dbConfigured() && (
          <div className="bg-focal text-ink text-sm font-semibold px-6 py-2.5">
            ⚠️ Supabase not configured — set SUPABASE_URL and
            SUPABASE_SERVICE_ROLE_KEY in <code>.env.local</code>.
          </div>
        )}
        <div className="max-w-[1180px] mx-auto px-6 py-7">{children}</div>
      </main>
    </div>
  );
}
