"use client";
import { useEffect, useState } from "react";

/**
 * A piece of UI state that survives navigation and reload.
 *
 * Filters were resetting every time you left a tab, so a search you had just
 * narrowed down was gone the moment you opened a row and came back. Kept in
 * localStorage rather than the URL because these are per-operator preferences,
 * not things you would paste to someone else.
 *
 * The stored value is read in an effect, never during render — reading
 * localStorage while rendering makes the server and client markup disagree and
 * React throws a hydration error.
 */
export function usePersisted<T>(key: string, initial: T): [T, (v: T) => void] {
  const [value, setValue] = useState<T>(initial);
  // STATE, not a ref. A ref is set synchronously, so on mount the write effect
  // ran straight after the read effect while `value` was still the default —
  // and promptly overwrote the value that had just been loaded. As state, the
  // flag forces a re-render first, so the write only ever sees the loaded value.
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    try {
      const raw = localStorage.getItem(`ui:${key}`);
      if (raw != null) setValue(JSON.parse(raw) as T);
    } catch {
      /* private mode, or someone hand-edited it — fall back to the default */
    }
    setHydrated(true);
  }, [key]);

  useEffect(() => {
    if (!hydrated) return;
    try {
      localStorage.setItem(`ui:${key}`, JSON.stringify(value));
    } catch {
      /* quota or private mode — persistence is a convenience, never required */
    }
  }, [key, value, hydrated]);

  return [value, setValue];
}
