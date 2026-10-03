-- ============================================================================
-- DOP Collect — one-shot: mark EXISTING agents as having used their trial.
--
-- Run this ONCE, immediately BEFORE flipping app_config.payments_enabled on.
--
-- Why it exists
-- -------------
-- While payments are off, `pay`'s status action hands back an ephemeral trial
-- and deliberately persists nothing (a row per agent id that ever opens the app
-- would be trial-row spam). The moment the switch flips, that same code path
-- starts writing a real row — so every agent already using the app, including
-- year-old ones, would be granted a fresh full trial and first revenue would be
-- one trial length away.
--
-- This closes that by writing an already-expired row for every agent that
-- exists right now. `resolve()` only grants a trial when there is NO row, so an
-- expired one means "you have had your go": existing agents meet the paywall,
-- and only genuinely new agents get a trial.
--
-- ORDER MATTERS
-- -------------
-- Run this BEFORE the flip. Afterwards, agents opening the app start creating
-- their own trial rows, and the `on conflict do nothing` below will (correctly)
-- refuse to overwrite them — so a late run silently misses exactly the people
-- it was meant to catch.
--
-- Basis: public.accounts.agent_id — the only place an agent id is bound to a
-- verified identity, and the same place `pay` derives entitlement from. An agent
-- who has not verified a phone by the time this runs has no session, so `pay`
-- cannot identify them anyway; when they do verify, they are indistinguishable
-- from a new user and will get a trial. That is intended.
--
-- Safe to re-run (it never overwrites an existing row). Not reversible in bulk —
-- to give an individual agent time back afterwards, use the dashboard:
-- Plans -> Subscribers -> Grant.
-- ============================================================================

-- 1. DRY RUN — how many agents is this about to close out?
--    Expect: to_close = the number of real agents live today.
select
  count(*) filter (where s.agent_id is null) as to_close,
  count(*) filter (where s.agent_id is not null) as already_have_a_row,
  count(*) as total_agents
from public.accounts a
left join public.subscriptions s on s.agent_id = a.agent_id
where coalesce(trim(a.agent_id), '') <> '';

-- 2. THE BACKFILL. Read the numbers above before running this.
insert into public.subscriptions
  (agent_id, plan_code, status, started_at, current_period_end, trial_used)
select distinct
  trim(a.agent_id),
  'trial',
  'expired',
  now(),
  now(),    -- ends immediately: `pay` reads access as current_period_end > now()
  true
from public.accounts a
where coalesce(trim(a.agent_id), '') <> ''
on conflict (agent_id) do nothing;

-- 3. VERIFY — every row this wrote must read as expired, with 0 days left.
--    Anything showing 'active' here was a pre-existing row and was left alone.
select status, count(*), min(days_left) as min_days, max(days_left) as max_days
from public.v_subscriptions
group by status
order by status;
