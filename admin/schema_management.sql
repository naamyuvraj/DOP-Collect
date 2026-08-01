-- ============================================================================
-- DOP Collect — management tables for the Next.js admin dashboard.
-- Run AFTER schema.sql, in the Supabase SQL editor.
-- ============================================================================

-- Managed LLM keys (feeds a future proxy so keys rotate without an app update).
create table if not exists public.app_keys (
  id          bigint generated always as identity primary key,
  provider    text default 'groq',
  label       text,
  key         text not null,
  enabled     boolean default true,
  created_at  timestamptz default now()
);
alter table public.app_keys enable row level security;
-- No anon policies -> only the dashboard's service_role key can touch this.

-- Remote app configuration (feature flags, force-update, announcement).
create table if not exists public.app_config (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz default now()
);
alter table public.app_config enable row level security;
-- The app may READ config (anon) to honour flags; only service_role writes.
drop policy if exists "anon read config" on public.app_config;
create policy "anon read config" on public.app_config
  for select to anon using (true);

-- Sensible defaults.
insert into public.app_config (key, value) values
  ('assistant_cloud',   'true'::jsonb),
  ('analytics_default', 'true'::jsonb),
  ('announcement',      '{"text":"","enabled":false}'::jsonb),
  ('force_update',      '{"version":"","message":"","enabled":false}'::jsonb)
on conflict (key) do nothing;
