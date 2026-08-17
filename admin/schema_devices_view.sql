-- ============================================================================
-- DOP Collect — v_devices, complete.
--
-- `v_devices` is defined in schema.sql and exposes only the columns `devices`
-- had at the time: id, agent_name, app_version, model, first_seen, last_seen,
-- events. Four columns were added to `devices` afterwards and never surfaced
-- through the view:
--
--   mobile      (schema_accounts.sql)
--   agent_id    (schema_regions.sql)
--   sol_id      (schema_regions.sql)
--   account_id  (schema_otp.sql)
--
-- So anything reading v_devices got null for all four, and the dashboard had to
-- query `devices` a SECOND time and reconcile the two in memory
-- (dashboard/lib/users.ts builds an `extra` map purely for this). Any other
-- reader — a SQL console, a report, a future page — silently saw nulls.
--
-- WHY THIS IS ITS OWN FILE
-- ------------------------
-- It cannot live in schema.sql. That file runs FIRST, before the three files
-- that add these columns, so a fresh deployment would fail on columns that do
-- not exist yet. This has to run after them.
--
-- ORDER: run AFTER schema.sql, schema_accounts.sql, schema_regions.sql and
-- schema_otp.sql. Safe to re-run; `create or replace view` and it holds no data.
-- ============================================================================

-- COLUMN ORDER IS NOT COSMETIC HERE.
--
-- `create or replace view` may only APPEND columns; it cannot insert them into
-- the middle. Putting `mobile` after `agent_name` made Postgres read it as a
-- rename of the existing fourth column and refuse:
--
--   42P16: cannot change name of view column "app_version" to "mobile"
--
-- So the seven original columns keep their exact names AND positions, and the
-- four new ones go on the end. Do not tidy this into a "nicer" order.
create or replace view public.v_devices as
  select
    coalesce(d.id, e.device_id)                          as id,
    d.agent_name,
    coalesce(d.app_version, e.last_version)              as app_version,
    d.model,
    coalesce(d.first_seen, e.first_event)                as first_seen,
    greatest(d.last_seen, e.last_event)                  as last_seen,
    coalesce(e.events, 0)                                as events,
    -- Appended (see above).
    d.mobile,
    d.agent_id,
    d.sol_id,
    d.account_id
  from public.devices d
  full outer join (
    select device_id,
           count(*)                                         as events,
           min(created_at)                                  as first_event,
           max(created_at)                                  as last_event,
           (array_agg(app_version order by created_at desc)
              filter (where app_version is not null))[1]    as last_version
    from public.events
    where device_id is not null
    group by device_id
  ) e on e.device_id = d.id;

-- VERIFY — expect all four of the late columns to be listed.
select column_name
from   information_schema.columns
where  table_schema = 'public' and table_name = 'v_devices'
  and  column_name in ('mobile', 'agent_id', 'sol_id', 'account_id')
order by column_name;
