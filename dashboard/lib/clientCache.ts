"use client";
// Tiny in-memory cache so switching tabs doesn't reload from scratch. It lives
// for the life of the SPA session (cleared on a hard refresh). A page seeds its
// state from the cache (instant, no skeleton) and only refetches when the entry
// is missing or older than TTL — so a repeat click shows data immediately and
// silently revalidates in the background.

type Entry = { data: unknown; at: number };
const store = new Map<string, Entry>();
const TTL = 30_000; // ms a cached tab is considered fresh

/** Last cached value for `key`, or null — regardless of age (for instant seed). */
export function peekCached<T>(key: string): T | null {
  return (store.get(key)?.data as T) ?? null;
}

/** True if a fresh (< TTL) entry exists — skip the refetch when so. */
export function isFresh(key: string): boolean {
  const e = store.get(key);
  return !!e && Date.now() - e.at < TTL;
}

export function setCached(key: string, data: unknown) {
  store.set(key, { data, at: Date.now() });
}
