import { admin, dbConfigured } from "./supabase";

export type Summary = {
  installs: number;
  active_1d: number;
  active_7d: number;
  active_30d: number;
  total_syncs: number;
  total_queries: number;
  revenue: number;
  key_calls_1d: number;
  // Core activity: lists made on the DOP portal + rupees collected through them.
  lists_submitted: number;
  collected_amount: number;
};

async function view<T>(name: string): Promise<T[]> {
  if (!dbConfigured()) return [];
  const { data, error } = await admin().from(name).select("*");
  if (error) {
    console.error(name, error.message);
    return [];
  }
  return (data as T[]) || [];
}

export async function getSummary(): Promise<Summary> {
  const rows = await view<Summary>("v_summary");
  return (
    rows[0] || {
      installs: 0,
      active_1d: 0,
      active_7d: 0,
      active_30d: 0,
      total_syncs: 0,
      total_queries: 0,
      revenue: 0,
      key_calls_1d: 0,
      lists_submitted: 0,
      collected_amount: 0,
    }
  );
}

export const getDaily = () =>
  view<{ day: string; dau: number; events: number }>("v_daily_active");
export const getEventTypes = () =>
  view<{ event: string; n: number; devices: number }>("v_events_by_type");
export const getKeyUsage = () =>
  view<{ key_index: number; calls: number; ok_calls: number; ok_pct: number }>(
    "v_key_usage"
  );
export const getRevenueByDay = () =>
  view<{ day: string; revenue: number; payments: number }>("v_revenue_by_day");
export const getCollections = () =>
  view<{ day: string; lists: number; accounts: number; amount: number }>(
    "v_collections"
  );

export async function recent<T>(
  table: string,
  cols = "*",
  limit = 25,
  order = "created_at"
): Promise<T[]> {
  if (!dbConfigured()) return [];
  const { data, error } = await admin()
    .from(table)
    .select(cols)
    .order(order, { ascending: false })
    .limit(limit);
  if (error) {
    console.error(table, error.message);
    return [];
  }
  return (data as T[]) || [];
}
