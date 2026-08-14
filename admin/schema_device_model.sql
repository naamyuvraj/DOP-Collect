-- DOP Collect — record which handset an install is running on.
--
-- Support starts with "which phone is this?", and a build that misbehaves on
-- one model is only visible as a pattern if the model is stored. The app sends
-- it with the rest of the device row (Analytics.identify -> ingest), so nothing
-- else has to change.
--
-- Safe to re-run.

alter table public.devices
  add column if not exists model text;

comment on column public.devices.model is
  'Handset name as the phone reports it, e.g. "Redmi Note 12". Written only by '
  'the ingest function; absent for installs that predate app 0.9.51.';

-- Fleet view: which handsets are actually in the field, most common first.
-- Useful before deciding what to test a release against.
create or replace view public.v_device_models as
select
  coalesce(nullif(trim(model), ''), 'unknown') as model,
  count(*)                                     as installs,
  count(*) filter (where last_seen > now() - interval '7 days') as active_7d,
  max(last_seen)                               as last_seen
from public.devices
group by 1
order by installs desc;
