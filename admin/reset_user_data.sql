-- ============================================================================
-- DOP Collect — RESET all user data for a clean slate.
-- ⚠️ DESTRUCTIVE. Wipes telemetry + verification state so that only NEW users
-- who log in with proper (OTP) verification from now on are tracked.
-- KEEPS: plans, app_config, subscriptions, payments (entitlements/financials).
-- Run in the Supabase SQL editor.
-- ============================================================================
truncate table
  public.events,
  public.key_usage,
  public.devices,
  public.accounts,
  public.device_sessions,
  public.otp_codes,
  public.otp_requests,
  public.proxy_rate
restart identity cascade;
