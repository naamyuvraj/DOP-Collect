-- ============================================================================
-- DOP Collect — MSG91 spend & volume for the admin dashboard's /otp page.
-- Run AFTER schema_otp.sql. Paste into Supabase → SQL Editor → Run. Re-runnable.
--
-- There is no per-message price anywhere in our data — MSG91 bills on its own
-- side and never tells the edge function what a send cost. So spend here is
-- ALWAYS an estimate: billable messages (which we do count exactly) × a rate
-- you type in on the dashboard. Treat it as a burn-rate signal, not an invoice;
-- the MSG91 wallet panel on the same page is the authority on what you owe.
-- ============================================================================

-- The rate the dashboard multiplies by, plus an optional monthly budget that
-- drives the "x% of budget used" bar. perMessage is in whole rupees (decimals
-- fine — WhatsApp auth templates are well under ₹1 a piece).
-- monthlyBudget 0 = no budget set, the bar is hidden.
insert into public.app_config (key, value) values
  ('otp_cost', '{"currency":"INR","perMessage":0.85,"monthlyBudget":0}'::jsonb)
on conflict (key) do nothing;

-- Per-day OTP volume. `sent` is the only column that costs money: one row =
-- one WhatsApp template message MSG91 accepted for delivery.
--
-- `blocked` is the opposite — sends our own rate limits refused BEFORE calling
-- MSG91, i.e. money not spent. Those rows only exist for requests made after
-- the edge function started logging them (see the logReq calls on the 429
-- paths in supabase/functions/otp/index.ts); older days read 0 because nothing
-- recorded them, not because nothing was blocked.
--
-- Days are IST calendar days, not UTC ones. `created_at` is timestamptz, so a
-- bare date_trunc would bucket on the session timezone — UTC on Supabase — and
-- put every send between midnight and 5:30am IST on the previous day. The
-- dashboard's JS fallback shifts by the same +05:30, so the two paths agree.
create or replace view public.v_otp_daily as
  select (created_at at time zone 'Asia/Kolkata')::date as day,
         count(*) filter (
           where action in ('send','resend') and status = 'ok')             as sent,
         count(*) filter (
           where action in ('send','resend') and status = 'provider_error') as failed,
         count(*) filter (
           where action in ('send','resend')
             and status in ('cooldown','rate_limited','not_configured'))    as blocked,
         count(*) filter (where action = 'verify' and status = 'ok')        as verified,
         count(*) filter (where action = 'verify' and status <> 'ok')       as verify_failed,
         count(distinct phone_hash) filter (
           where action in ('send','resend') and status = 'ok')             as phones
  from public.otp_requests
  group by 1;

-- Why sends fail or get refused, newest window first. Feeds the failure table;
-- 'ok' is excluded because that table is only about what went wrong.
create or replace view public.v_otp_failures as
  select action, status, count(*) as n, max(created_at) as last_seen
  from public.otp_requests
  where status <> 'ok'
  group by 1, 2;

-- Heaviest phones by billable sends. phone_hash only — the raw number is never
-- stored, so the dashboard shows a hash prefix. A phone with many sends and no
-- verify is the shape of someone burning your credits without ever signing in.
create or replace view public.v_otp_top_phones as
  select phone_hash,
         count(*) filter (
           where action in ('send','resend') and status = 'ok')      as sent,
         count(*) filter (where action = 'verify' and status = 'ok') as verified,
         count(*) filter (
           where action in ('send','resend')
             and status in ('cooldown','rate_limited'))              as blocked,
         min(created_at) as first_seen,
         max(created_at) as last_seen
  from public.otp_requests
  group by 1;
