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
-- SECURITY (SECURITY_AUDIT.md S13): scope anon reads to CLIENT-FACING keys only.
-- Server-only thresholds (groq_limits, otp_limits, require_integrity, max_devices,
-- otp_required, trial_days…) are read by edge functions with the service role,
-- which bypasses RLS — so keeping them out of the anon allowlist stops anyone who
-- extracts the APK's anon key from reading our exact rate-limit thresholds.
-- Add a new key here whenever the app itself needs to read it.
drop policy if exists "anon read config" on public.app_config;
-- The app reads these with the ANON key, so a key missing from this list is
-- silently filtered out by RLS — no error, just the hardcoded default forever.
-- `self_serve_billing` and `max_devices` were read by RemoteConfig and absent
-- here, so self-serve billing could never be switched on remotely and the
-- device limit was stuck at its built-in 3 whatever the dashboard said.
--
-- Keep this in step with the `_flag`/`_int`/`_str` calls in
-- lib/services/remote_config.dart. Nothing warns when they drift.
create policy "anon read config" on public.app_config
  for select to anon using (key in (
    'assistant_cloud', 'analytics_default', 'portal_submit',
    'payments_enabled', 'announcement', 'force_update', 'otp_required',
    'self_serve_billing', 'max_devices'
  ));

-- Sensible defaults.
insert into public.app_config (key, value) values
  ('assistant_cloud',   'true'::jsonb),
  ('analytics_default', 'true'::jsonb),
  ('portal_submit',     'true'::jsonb),
  ('announcement',      '{"text":"","enabled":false}'::jsonb),
  ('force_update',      '{"version":"","message":"","enabled":false}'::jsonb),
  -- These two are read by RemoteConfig and were never seeded, so the app fell
  -- back to its built-in defaults no matter what the RLS policy allowed — a row
  -- that does not exist cannot be returned. Allowlisting a key is only half of
  -- making it reachable; it needs a row too.
  ('self_serve_billing', 'false'::jsonb),
  ('max_devices',        '3'::jsonb)
on conflict (key) do nothing;
