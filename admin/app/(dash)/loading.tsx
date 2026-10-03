// Shown instantly on every navigation into a dashboard page while its server
// render (and Supabase round-trips) complete. Without this, App Router blocks
// on the previous screen with no feedback — which reads as "lag". A light
// skeleton makes navigation feel immediate.
export default function Loading() {
  return (
    <div className="animate-pulse">
      <div className="flex items-end justify-between mb-5">
        <div>
          <div className="h-6 w-40 rounded-lg bg-line" />
          <div className="h-3 w-56 rounded bg-line mt-3" />
        </div>
      </div>

      <div className="grid gap-4 grid-cols-2 md:grid-cols-3 lg:grid-cols-6">
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="card p-[18px]">
            <div className="h-2.5 w-14 rounded bg-line" />
            <div className="h-7 w-20 rounded-lg bg-line mt-3" />
          </div>
        ))}
      </div>

      <div className="grid gap-4 mt-4 lg:grid-cols-[1.4fr_1fr]">
        <div className="card p-[18px] h-[264px]" />
        <div className="card p-[18px] h-[264px]" />
      </div>

      <div className="card p-[18px] mt-4 h-[220px]" />
    </div>
  );
}
