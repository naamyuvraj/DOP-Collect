import { createClient } from "@supabase/supabase-js";

// SERVER-ONLY Supabase client using the service_role key. Never import this
// into a client component — the key must never reach the browser.
export function admin() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error(
      "Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in .env.local"
    );
  }
  return createClient(url, key, { auth: { persistSession: false } });
}

export const dbConfigured = () =>
  !!process.env.SUPABASE_URL && !!process.env.SUPABASE_SERVICE_ROLE_KEY;
