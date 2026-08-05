-- ============================================================================
-- DOP Collect — OTP identity + device-session schema (MSG91).
-- Run AFTER schema.sql (needs pgcrypto) and schema_ratelimit.sql (bump_rate).
-- Paste into Supabase → SQL Editor → Run. Safe to re-run.
-- Only the `otp` edge function (service role) touches these tables — there are
-- NO anon policies, so the app can never read them directly.
-- ============================================================================

-- One verified account per phone; bound 1:1 to a DOP Agent ID.
create table if not exists public.accounts (
  id          uuid primary key default gen_random_uuid(),
  phone_hash  text unique not null,          -- sha256(91xxxxxxxxxx)
  agent_id    text unique,                    -- DOP portal login (1:1)
  disabled    boolean default false,          -- admin kill switch per account
  created_at  timestamptz not null default now()
);

-- Active device sessions. Max N (app_config.max_devices, default 2) non-revoked
-- per account; the edge function kicks the oldest on the (N+1)th verify.
create table if not exists public.device_sessions (
  id             uuid primary key default gen_random_uuid(),
  account_id     uuid references public.accounts(id) on delete cascade,
  device_id      text not null,
  token_hash     text not null,               -- sha256(session token)
  app_version    text,
  created_at     timestamptz not null default now(),
  last_seen      timestamptz not null default now(),
  revoked_at     timestamptz,
  revoked_reason text                          -- device_limit | admin | logout
);
create unique index if not exists uq_sessions_account_device
  on public.device_sessions (account_id, device_id);
create index if not exists idx_sessions_live
  on public.device_sessions (account_id) where revoked_at is null;
create index if not exists idx_sessions_token on public.device_sessions (token_hash);

-- OTP attempts — rate-limit audit (no raw phone, no code).
create table if not exists public.otp_requests (
  id          bigint generated always as identity primary key,
  device_id   text,
  phone_hash  text not null,
  req_id      text,
  action      text not null,                  -- send | resend | verify
  status      text not null,                  -- ok | invalid | expired | ...
  created_at  timestamptz not null default now()
);
create index if not exists idx_otp_phone_time on public.otp_requests (phone_hash, created_at);

-- Attribute payments to the account (survives phone swaps within the 2-device
-- rule); the app sends its accountId when recording a payment.
alter table public.payments add column if not exists account_id uuid references public.accounts(id);

-- devices: surface verification in the Users & Devices view.
alter table public.devices add column if not exists account_id     uuid references public.accounts(id);
alter table public.devices add column if not exists phone_verified boolean default false;

alter table public.accounts        enable row level security;
alter table public.device_sessions enable row level security;
alter table public.otp_requests    enable row level security;
-- No anon policies on purpose → only the service-role edge function reads/writes.

-- Config defaults (dashboard-tunable). otp_required gates onboarding; ship off.
insert into public.app_config (key, value) values
  ('otp_required', 'false'::jsonb),
  ('max_devices',  '2'::jsonb),
  ('otp_limits',   '{"cooldown":30,"maxSendPerHour":5}'::jsonb)
on conflict (key) do nothing;
