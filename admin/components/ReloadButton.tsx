"use client";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";

/**
 * Reload for a tab.
 *
 * Two shapes, because the tabs are two shapes: a server-rendered page needs its
 * ISR entry dropped and the route re-run, while a client-fetched page just
 * refetches. Pass `path` for the former, `onReload` for the latter.
 */
export default function ReloadButton({
  path,
  onReload,
  label = "Reload",
}: {
  path?: string;
  onReload?: () => Promise<unknown> | void;
  label?: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [busy, setBusy] = useState(false);
  const running = pending || busy;

  async function go() {
    setBusy(true);
    try {
      if (path) {
        await fetch("/api/revalidate", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ path }),
        }).catch(() => {});
        startTransition(() => router.refresh());
      }
      if (onReload) await onReload();
    } finally {
      setBusy(false);
    }
  }

  return (
    <button className="btn btn-ghost" onClick={go} disabled={running} title="Fetch the latest data">
      {running ? "Reloading…" : label}
    </button>
  );
}
