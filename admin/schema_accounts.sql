-- ============================================================================
-- DOP Collect — accounts under management (how big each agent's book is).
-- Run in the Supabase SQL editor (after schema.sql). Safe to re-run.
--
-- Every full portal sync emits a `sync_done` event carrying {accounts: N} — the
-- number of RD accounts that agent maintains. These views expose, per agent and
-- in total, how many accounts are under management across all installs.
-- Read-only telemetry; service_role only.
-- ============================================================================

-- The agent's display name (shown on the Users tab). Sent by the app with its
-- telemetry; nullable until the app update that sends it ships.
alter table public.devices add column if not exists name text;

-- Latest known account count per device (from its most recent sync_done).
create or replace view public.v_agent_accounts as
  select distinct on (device_id)
    device_id,
    (props->>'accounts')::int as accounts,
    created_at                as last_sync
  from public.events
  where event = 'sync_done'
    and props ? 'accounts'
    and (props->>'accounts') ~ '^[0-9]+$'
  order by device_id, created_at desc;

-- Totals across every agent that has synced at least once.
create or replace view public.v_accounts_summary as
  select
    count(*)                              as agents,
    coalesce(sum(accounts), 0)            as total_accounts,
    coalesce(round(avg(accounts)), 0)::int as avg_accounts,
    coalesce(max(accounts), 0)            as max_accounts
  from public.v_agent_accounts;
