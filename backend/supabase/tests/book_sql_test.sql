-- ============================================================================
-- DOP Collect — book sync, tested against a real Postgres.
--
-- The other files in this directory are Deno tests for the edge functions.
-- This one is SQL because everything it checks lives in the database: the
-- last-write-wins comparison and the composite pull cursor are in
-- backend/schema/schema_book.sql precisely BECAUSE they cannot be done safely in
-- TypeScript, so testing them through the function would be testing the wrong
-- layer.
--
-- HOW TO RUN (throwaway cluster, ~10 seconds):
--
--   SOCK=$(mktemp -d /tmp/pgs.XXXX)
--   export PGDATA=/tmp/pgdata-book
--   initdb -U postgres -A trust $PGDATA
--   pg_ctl -D $PGDATA -o "-p 55432 -k $SOCK -c listen_addresses=" -l /tmp/pg.log start
--   psql -h $SOCK -p 55432 -U postgres -c 'create database book'
--   psql -h $SOCK -p 55432 -U postgres -d book -v ON_ERROR_STOP=1 -f supabase/tests/book_sql_test.sql
--   pg_ctl -D $PGDATA stop
--
-- Every check is an `assert`, so the script exits non-zero on the first
-- failure. Passing prints ALL ASSERTIONS PASSED.
-- ============================================================================

-- Stand-ins for what schema.sql / schema_otp.sql create in the real project.
-- Only what schema_book.sql actually references.

create extension if not exists "pgcrypto";
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role;  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon;          end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
end $$;
create table if not exists public.accounts (
  id       uuid primary key default gen_random_uuid(),
  agent_id text unique,
  disabled boolean not null default false
);

\ir ../../schema/schema_book.sql

do $t$
declare
  acct uuid;
  n int; got int; c record; t0 timestamptz; k text; total int;
begin
  insert into public.accounts (agent_id) values ('TEST-' || gen_random_uuid())
    returning id into acct;

  -- 1 -----------------------------------------------------------------------
  -- A first sync pushes the whole book at once. 1,500 accounts is the largest
  -- book the competitor's pricing tiers acknowledge, so it is the size worth
  -- proving against.
  select public.book_push_accounts(acct,
    (select jsonb_agg(jsonb_build_object(
       'account_number', lpad(i::text, 10, '0'),
       'customer_name', 'Cust ' || i,
       'denomination_amount', 100 * i,
       'months_paid', 3,
       'client_updated_at', now()))
     from generate_series(1, 1500) i), 'phone') into n;
  assert n = 1500, 'expected 1500 pushed, got ' || n;

  -- THE hazard this schema exists to survive. `now()` is transaction time, so
  -- all 1,500 rows carry ONE timestamp. A cursor of "updated_at > last seen"
  -- would read the first page and then skip the remaining 1,100 rows forever —
  -- silently, with no error, on every agent with a real book.
  select count(distinct updated_at) into got
    from public.book_accounts where account_id = acct;
  assert got = 1, 'test no longer reproduces the shared-timestamp case';

  -- 2 -----------------------------------------------------------------------
  -- The composite (updated_at, key) cursor must drain all of it.
  t0 := 'epoch'; k := ''; total := 0;
  loop
    got := 0;
    for c in select * from public.book_pull_accounts(acct, t0, k, 400, 'desktop') loop
      t0 := c.updated_at; k := c.account_number; got := got + 1;
    end loop;
    total := total + got;
    exit when got = 0;
    assert total <= 1500, 'cursor looped forever at ' || total;
  end loop;
  assert total = 1500, 'paging lost rows: ' || total;

  -- 3 -----------------------------------------------------------------------
  -- Echo guard: the device that wrote the rows must not download them back.
  select count(*) into got
    from public.book_pull_accounts(acct, 'epoch', '', 5000, 'phone');
  assert got = 0, 'echo guard failed, phone re-pulled ' || got || ' of its own rows';

  -- 4 -----------------------------------------------------------------------
  -- Last-write-wins on the CLIENT clock. A phone that has been offline for a
  -- week reconnects and pushes its stale copy; it must not overwrite an edit
  -- made on the desktop yesterday. This is the case that would quietly undo an
  -- agent's work, so it is the one worth an assert.
  perform public.book_push_accounts(acct, jsonb_build_array(jsonb_build_object(
    'account_number', '0000000001',
    'customer_name',  'FRESH desktop edit',
    'client_updated_at', now())), 'desktop');
  perform public.book_push_accounts(acct, jsonb_build_array(jsonb_build_object(
    'account_number', '0000000001',
    'customer_name',  'STALE week-old phone copy',
    'client_updated_at', now() - interval '7 days')), 'phone');
  select customer_name into k from public.book_accounts
    where account_id = acct and account_number = '0000000001';
  assert k = 'FRESH desktop edit', 'stale write won: ' || k;

  -- 5 -----------------------------------------------------------------------
  -- The same key twice in one batch. Without `distinct on` in the push RPC,
  -- Postgres raises "ON CONFLICT DO UPDATE command cannot affect row a second
  -- time" and the ENTIRE push aborts — so one duplicated row (a retry, a double
  -- tap) would block that agent from syncing anything at all.
  select public.book_push_collections(acct, jsonb_build_array(
    jsonb_build_object('uid','dup-1','account_number','0000000001','amount',100,
      'collected_at','2026-08-30T10:00:00Z','cycle_ym','2026-08',
      'client_updated_at', now() - interval '1 hour'),
    jsonb_build_object('uid','dup-1','account_number','0000000001','amount',250,
      'collected_at','2026-08-30T11:00:00Z','cycle_ym','2026-08',
      'client_updated_at', now())
  ), 'phone') into n;
  select amount into got from public.book_collections
    where account_id = acct and uid = 'dup-1';
  assert got = 250, 'in-batch dedupe kept the wrong row: ' || got;

  -- 6 -----------------------------------------------------------------------
  -- A tombstone has to travel. An undone collection is money the agent says he
  -- did not take; if the delete never reaches the other device, the two
  -- disagree about cash.
  perform public.book_push_collections(acct, jsonb_build_array(
    jsonb_build_object('uid','dup-1','account_number','0000000001','amount',250,
      'collected_at','2026-08-30T11:00:00Z','cycle_ym','2026-08',
      'deleted', true, 'client_updated_at', now() + interval '1 second')), 'phone');
  select count(*) into got
    from public.book_pull_collections(acct, 'epoch', '', 100, 'desktop')
    where deleted;
  assert got = 1, 'tombstone did not travel';

  -- 7 -----------------------------------------------------------------------
  -- Books are per-agent. A second agent must see none of the first one's rows
  -- even though both call the same function.
  declare other uuid;
  begin
    insert into public.accounts (agent_id) values ('OTHER-' || gen_random_uuid())
      returning id into other;
    select count(*) into got
      from public.book_pull_accounts(other, 'epoch', '', 5000, 'desktop');
    assert got = 0, 'agent isolation broken: saw ' || got || ' foreign rows';
  end;

  raise notice 'ALL ASSERTIONS PASSED';
end;
$t$;
