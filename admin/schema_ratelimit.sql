-- ============================================================================
-- DOP Collect — rate limiting for the `groq` edge function (proxy abuse guard).
-- Run in the Supabase SQL editor. Also drops the risky anon-insert on payments.
-- ============================================================================

-- Sliding-window counters (service_role only; edge function bumps them).
create table if not exists public.proxy_rate (
  device_id     text not null,
  window_start  timestamptz not null,
  count         int not null default 0,
  primary key (device_id, window_start)
);
alter table public.proxy_rate enable row level security;
-- No policies -> only the service_role key (edge function) can touch it.

-- Atomic "increment and return the new count for the current window".
create or replace function public.bump_rate(p_device text, p_window_secs int)
returns int
language plpgsql
security definer
as $$
declare
  w timestamptz := to_timestamp(
    floor(extract(epoch from now()) / p_window_secs) * p_window_secs);
  c int;
begin
  insert into public.proxy_rate(device_id, window_start, count)
    values (p_device, w, 1)
  on conflict (device_id, window_start)
    do update set count = public.proxy_rate.count + 1
  returning count into c;
  return c;
end;
$$;

-- Ensure app_config exists (normally created by schema_management.sql) so this
-- script runs standalone / in any order.
create table if not exists public.app_config (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz default now()
);
alter table public.app_config enable row level security;
drop policy if exists "anon read config" on public.app_config;
create policy "anon read config" on public.app_config
  for select to anon using (true);

-- Optional: tune the proxy limits from the dashboard (App Config). Defaults
-- baked into the edge function are used if this row is absent.
insert into public.app_config (key, value) values
  ('groq_limits', '{"perMin":20,"perDay":600,"perIpHour":400}'::jsonb)
on conflict (key) do nothing;

-- Housekeeping: prune old windows (call occasionally, or via a cron job).
create or replace function public.prune_proxy_rate()
returns void language sql security definer as $$
  delete from public.proxy_rate where window_start < now() - interval '2 days';
$$;

-- ---------------------------------------------------------------------------
-- SECURITY FIX: payments must never be inserted by the public anon key
-- (anyone could forge "success" rows). Insert them server-side only.
-- ---------------------------------------------------------------------------
drop policy if exists "anon insert payments" on public.payments;
