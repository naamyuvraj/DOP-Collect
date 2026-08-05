-- ============================================================================
-- DOP Collect — subscriptions & payments (Razorpay).
-- Run AFTER schema.sql. Safe to re-run. Only the `pay` edge function (service
-- role) writes subscriptions/payments; the app reads plans (anon) + calls `pay`.
--
-- Entitlement is keyed by the DOP agent_id (portal login) — stable per agent,
-- no OTP needed. Everything is gated by app_config.payments_enabled (ships off).
-- ============================================================================

-- Plans the app offers. Dashboard-editable (prices are placeholders — set real
-- ones in the Config/Plans page). Trial is just a 0-price plan.
create table if not exists public.plans (
  code          text primary key,              -- trial | monthly | quarterly | yearly
  name          text not null,
  price_inr     numeric(10,2) not null default 0,
  duration_days int not null,
  active        boolean default true,
  sort          int default 0
);
insert into public.plans (code, name, price_inr, duration_days, active, sort) values
  ('trial',     'Free trial', 0,    14,  true, 0),
  ('monthly',   'Monthly',    199,  30,  true, 1),
  ('quarterly', 'Quarterly',  499,  90,  true, 2),
  ('yearly',    'Yearly',     1499, 365, true, 3)
on conflict (code) do nothing;

-- One row per agent. current_period_end is the source of truth for access.
create table if not exists public.subscriptions (
  agent_id           text primary key,
  plan_code          text references public.plans(code),
  status             text not null default 'trial',   -- trial | active | expired
  started_at         timestamptz not null default now(),
  current_period_end timestamptz not null,
  trial_used         boolean default true,
  updated_at         timestamptz default now()
);
create index if not exists idx_subs_period on public.subscriptions (current_period_end);

-- Payments: link to the agent + plan + Razorpay ids (extends existing table).
alter table public.payments add column if not exists agent_id  text;
alter table public.payments add column if not exists plan_code text;
alter table public.payments add column if not exists order_id  text;

-- Idempotency: one payment row per Razorpay payment id. Blocks a replayed
-- signature from stacking free subscription time even under a race (the `pay`
-- function relies on this insert failing on a duplicate).
create unique index if not exists uq_payments_razorpay_ref
  on public.payments (ref) where provider = 'razorpay' and ref is not null;

alter table public.plans         enable row level security;
alter table public.subscriptions enable row level security;
-- Plans are public pricing → anon may read. Subscriptions: service role only.
drop policy if exists "anon read plans" on public.plans;
create policy "anon read plans" on public.plans for select to anon using (true);

-- Config: master switch (ship OFF) + trial length. Razorpay keys are Supabase
-- secrets (RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET), never in these tables.
insert into public.app_config (key, value) values
  ('payments_enabled', 'false'::jsonb),
  ('trial_days',       '14'::jsonb)
on conflict (key) do nothing;

-- Revenue + active-subscriber views for the dashboard.
create or replace view public.v_subscriptions as
  select s.agent_id, s.plan_code, p.name as plan_name,
         case when s.current_period_end > now()
              then s.status else 'expired' end as status,
         s.started_at, s.current_period_end,
         greatest(0, ceil(extract(epoch from (s.current_period_end - now()))/86400))::int as days_left
  from public.subscriptions s
  left join public.plans p on p.code = s.plan_code
  order by s.current_period_end desc;

create or replace view public.v_mrr as
  select date_trunc('day', created_at)::date as day,
         coalesce(sum(amount),0) as revenue, count(*) as payments
  from public.payments
  where status = 'success' and provider = 'razorpay'
  group by 1 order by 1;
