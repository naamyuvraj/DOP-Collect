-- ============================================================================
-- DOP Collect — lock down the public anon key (Play Store hardening).
-- Run AFTER schema.sql. Safe to re-run.
--
-- Before: the app INSERTed telemetry straight into these tables with the anon
-- key baked into the APK, so anyone could spam events/devices or FORGE payment
-- rows. After: the only writer is the `ingest` edge function (service role);
-- the anon key can do nothing but READ app_config.
--
-- ORDER OF OPERATIONS (important — don't lock out live installs):
--   1. Deploy the `ingest` function.
--   2. Ship the app patch that routes telemetry through it.
--   3. THEN run this file. (Running it before step 2 just means not-yet-updated
--      installs stop reporting analytics — harmless, but wait if you can.)
-- ============================================================================

-- Telemetry: no more anon writes (the `ingest` service-role function does it).
drop policy if exists "anon insert events"    on public.events;
drop policy if exists "anon insert key_usage" on public.key_usage;
drop policy if exists "anon insert devices"   on public.devices;
drop policy if exists "anon update devices"   on public.devices;

-- Payments: never anon-writable. Forged revenue rows were the worst vector; the
-- app never inserts payments from the client anyway (real payments will go
-- through a trusted server path).
drop policy if exists "anon insert payments"  on public.payments;

-- RLS stays enabled with NO anon insert/update policies => anon is denied all
-- writes here. The only remaining anon policy in the project is
-- "anon read config" (app_config SELECT), which is intended.

-- Play Integrity gate for the edge functions (dormant until the Play Store
-- release wires the native token). Flip to true only after that ships.
insert into public.app_config (key, value) values
  ('require_integrity', 'false'::jsonb)
on conflict (key) do nothing;
