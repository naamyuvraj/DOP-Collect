-- ============================================================================
-- DOP Collect — Analytics schema for Supabase
-- ----------------------------------------------------------------------------
-- HOW TO USE:
--   1. Supabase dashboard -> SQL Editor -> New query -> paste ALL of this -> Run.
--   2. Project Settings -> API -> copy the Project URL and the two keys.
--   3. App:  paste URL + anon (public) key into lib/services/supabase_config.dart
--   4. Dashboard: paste URL + service_role key into admin/dashboard.html
--
-- PRIVACY: the app never writes customer data here — only anonymous device ids,
-- event names, small numeric props (counts/amounts), and payments. No customer
-- names, account numbers, or the questions typed into the assistant.
--
-- SECURITY MODEL:
--   * The app uses the ANON key and may only INSERT its own telemetry (RLS).
--   * The dashboard uses the SERVICE_ROLE key (bypasses RLS, full read). Keep
--     that key private — do NOT deploy the dashboard publicly with it inline.
-- ============================================================================

create extension if not exists "pgcrypto";

-- One row per install (anonymous device) -------------------------------------
create table if not exists public.devices (
  id           text primary key,                 -- app-generated uuid v4
  agent_name   text,                              -- optional label (from setup)
  app_version  text,
  platform     text default 'android',
  model        text,
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now()
);

-- Activity / analytics events ------------------------------------------------
create table if not exists public.events (
  id           bigint generated always as identity primary key,
  device_id    text,
  event        text not null,                     -- app_open, sync_done, ...
  props        jsonb not null default '{}'::jsonb,
  app_version  text,
  created_at   timestamptz not null default now()
);
create index if not exists idx_events_created on public.events (created_at);
create index if not exists idx_events_event   on public.events (event);
create index if not exists idx_events_device  on public.events (device_id);

-- LLM key rotation / usage (tracks the 4 Groq keys) --------------------------
create table if not exists public.key_usage (
  id          bigint generated always as identity primary key,
  device_id   text,
  key_index   int,                                -- which key (0..n)
  model       text,
  ok          boolean default true,               -- succeeded / rate-limited
  created_at  timestamptz not null default now()
);
create index if not exists idx_key_usage_created on public.key_usage (created_at);

-- Payments (for when the app is monetized) -----------------------------------
create table if not exists public.payments (
  id          bigint generated always as identity primary key,
  device_id   text,
  amount      numeric(10,2) not null,
  currency    text default 'INR',
  plan        text,                               -- e.g. 'pro_monthly'
  provider    text,                               -- razorpay / play_billing
  ref         text,                               -- provider reference id
  status      text default 'success',             -- success / pending / failed
  created_at  timestamptz not null default now()
);
create index if not exists idx_payments_created on public.payments (created_at);

-- Row Level Security ----------------------------------------------------------
alter table public.devices    enable row level security;
alter table public.events     enable row level security;
alter table public.key_usage  enable row level security;
alter table public.payments   enable row level security;

-- The app (anon) may INSERT telemetry and keep a device row fresh, nothing else.
-- (No SELECT policies for anon -> only the service_role key can read the data.)
create policy "anon insert devices"   on public.devices   for insert to anon with check (true);
create policy "anon update devices"   on public.devices   for update to anon using (true) with check (true);
create policy "anon insert events"    on public.events    for insert to anon with check (true);
create policy "anon insert key_usage" on public.key_usage for insert to anon with check (true);
create policy "anon insert payments"  on public.payments  for insert to anon with check (true);

-- Convenience views the dashboard reads (service_role) ------------------------
create or replace view public.v_daily_active as
  select date_trunc('day', created_at)::date as day,
         count(distinct device_id)           as dau,
         count(*)                            as events
  from public.events
  group by 1 order by 1;

create or replace view public.v_events_by_type as
  select event, count(*) as n, count(distinct device_id) as devices
  from public.events
  group by 1 order by 2 desc;

create or replace view public.v_revenue_by_day as
  select date_trunc('day', created_at)::date as day,
         sum(amount) as revenue, count(*) as payments
  from public.payments
  where status = 'success'
  group by 1 order by 1;

create or replace view public.v_key_usage as
  select key_index,
         count(*)                                     as calls,
         sum((ok)::int)                               as ok_calls,
         round(100.0 * sum((ok)::int) / count(*), 1)  as ok_pct
  from public.key_usage
  group by 1 order by 1;

-- Quick top-line numbers ------------------------------------------------------
create or replace view public.v_summary as
  select
    (select count(*) from public.devices)                                         as installs,
    (select count(distinct device_id) from public.events
       where created_at > now() - interval '1 day')                               as active_1d,
    (select count(distinct device_id) from public.events
       where created_at > now() - interval '7 day')                               as active_7d,
    (select count(distinct device_id) from public.events
       where created_at > now() - interval '30 day')                              as active_30d,
    (select count(*) from public.events where event = 'sync_done')                as total_syncs,
    (select count(*) from public.events where event = 'assistant_query')          as total_queries,
    (select coalesce(sum(amount),0) from public.payments where status='success')  as revenue,
    (select count(*) from public.key_usage where created_at > now() - interval '1 day') as key_calls_1d;
