-- ============================================================================
-- DOP Collect — two agent names become one.
--
-- Onboarding used to capture "Name" (display) and "Agent Name" (the DOP
-- paperwork one) into devices.name and devices.agent_name. Agents filled either
-- or both, so neither column could be trusted alone. There is now ONE name,
-- `agent_name`, and this rescues anything left in `name` before dropping it.
--
-- ORDER MATTERS — step 3 is irreversible
-- --------------------------------------
-- Deploy the new `ingest` and the new dashboard FIRST. Three things used to
-- write devices.name: the ingest upsert, the dashboard PATCH route, and the
-- agent drawer. All three have stopped, but only in the NEW builds. Drop the
-- column while the old ingest is still live and every device upsert fails with
-- 42703 ("column does not exist") — that path has a fallback for `model` only,
-- so last_seen, mobile and agent id would stop landing too.
--
--   1. supabase functions deploy ingest --use-api --project-ref ojorpmtptryldizogtkz
--   2. deploy the dashboard
--   3. then run this file, top to bottom
-- ============================================================================

-- 1. RESCUE. Fills a BLANK agent_name only, so an agent who set both keeps the
--    name that appears on his receipts. Mirrors AppSettings.migrateLegacyName()
--    on the device exactly. Safe to re-run.
update public.devices
set    agent_name = trim(name)
where  coalesce(trim(agent_name), '') = ''
  and  coalesce(trim(name), '')      <> '';

-- 2. CHECK before the drop. `unrescued` MUST be 0 — anything else means step 1
--    did not run. Do not continue until it reads 0.
select
  count(*) filter (
    where coalesce(trim(agent_name), '') = ''
      and coalesce(trim(name), '')      <> ''
  ) as unrescued,
  count(*) filter (where coalesce(trim(agent_name), '') <> '') as named,
  count(*) as total_devices
from public.devices;

-- 3. THE DROP. Irreversible. Read the numbers above first.
alter table public.devices drop column if exists name;

-- 4. VERIFY — expect one row, `agent_name`, and no `name`.
select column_name
from   information_schema.columns
where  table_schema = 'public' and table_name = 'devices'
  and  column_name in ('name', 'agent_name');
