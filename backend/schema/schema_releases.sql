-- ============================================================================
-- DOP Collect — release / patch log + fleet version adoption.
-- Run in the Supabase SQL editor (any order after schema.sql). Safe to re-run.
--
-- The dashboard's Releases page uses this to keep a maintained record of every
-- release/Shorebird patch over time, and to show how each version has rolled
-- out across installs (from the anonymous telemetry the app already sends).
-- Only the dashboard's service_role key reads/writes `releases` (no anon policy).
-- ============================================================================

create table if not exists public.releases (
  id              bigint generated always as identity primary key,
  version         text not null,                 -- e.g. 0.9.43+16
  kind            text not null default 'patch', -- release | patch
  channel         text default 'stable',         -- stable | beta
  shorebird_patch int,                            -- Shorebird patch number, if a patch
  git_sha         text,                           -- commit this shipped from
  notes           text,                           -- changelog / what changed
  created_at      timestamptz not null default now()
);
create index if not exists idx_releases_created on public.releases (created_at desc);
alter table public.releases enable row level security;  -- dashboard (service_role) only

-- Fleet adoption: how many installs / events are on each app_version, and when
-- that version was last seen in the wild. Drives the "who is on which patch"
-- table on the dashboard.
create or replace view public.v_app_versions as
  select
    app_version,
    count(distinct device_id) as devices,
    count(*)                  as events,
    min(created_at)           as first_seen,
    max(created_at)           as last_seen
  from public.events
  where app_version is not null and app_version <> ''
  group by app_version
  order by max(created_at) desc;
