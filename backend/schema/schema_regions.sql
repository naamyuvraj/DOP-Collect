-- ============================================================================
-- DOP Collect — per-agent / per-region tracking.
-- Run in the Supabase SQL editor (after schema.sql). Safe to re-run.
--
-- Adds the DOP agent id + its SOL ID (post-office branch code) to the device
-- telemetry so the dashboard can show WHICH BRANCHES / REGIONS use the app.
-- A DOP agent id is MI + <SOL ID> + <5-digit sequence>; the SOL ID is the
-- region key. Only the dashboard's service_role key reads these (no anon read).
--
-- NOTE: these columns stay empty until the app is updated to send sol_id/agent_id
-- (and the `ingest` edge function is redeployed to forward them). Until then the
-- Regions page derives regions from `subscriptions.agent_id`.
-- ============================================================================

alter table public.devices add column if not exists agent_id text;
alter table public.devices add column if not exists sol_id   text;
create index if not exists idx_devices_sol on public.devices (sol_id);

-- Installs grouped by branch / region (SOL ID).
create or replace view public.v_regions as
  select
    sol_id,
    count(*)                                                          as installs,
    count(*) filter (where last_seen > now() - interval '7 day')      as active_7d,
    count(distinct agent_id)                                          as agents,
    max(last_seen)                                                    as last_seen
  from public.devices
  where sol_id is not null and sol_id <> ''
  group by sol_id
  order by count(*) desc;
