-- ============================================================================
-- DOP Collect — the book, in the cloud.
-- Run in the Supabase SQL editor (after schema.sql and schema_otp.sql).
-- Safe to re-run.
--
-- WHY THIS EXISTS
-- ---------------
-- Until now Supabase held telemetry, OTP sessions and payments — and nothing
-- an agent would miss. The book itself (accounts, the collections ledger, saved
-- lists) lived only in the handset's SQLCipher file. That was a deliberate
-- privacy position and it is why the desktop app has no data to show: there is
-- nothing on the server to show it.
--
-- These three tables are the smallest thing that lets a second device see the
-- same book. They are NOT telemetry and they are NOT the analytics schema's
-- job: rows here belong to one agent, are readable only through a live device
-- session, and are what that agent typed or synced — customer names and account
-- numbers included. Treat this file as the line where that changes, and keep
-- the Privacy Policy in step with it.
--
-- WHAT IS *NOT* HERE, ON PURPOSE
-- ------------------------------
--   * DOP portal credentials. They stay in the handset Keystore. The server
--     must never be able to log in as the agent — that is the whole difference
--     between us and the competitor, who writes `dopPassword` to Firestore in
--     plaintext.
--   * Anything derived. The khata is a SUM over `book_collections`; it is built
--     on read, never stored, exactly as it is on the device.
--
-- SECURITY MODEL
-- --------------
-- No anon policies. RLS is on and empty, so the only reader/writer is the
-- `sync` edge function running as service_role, which resolves a session token
-- to an account_id before it touches a row. A stolen anon key gets nothing.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Shared shape
-- ---------------------------------------------------------------------------
-- Every table below carries the same four sync columns, and they earn their
-- keep in different ways:
--
--   account_id         which agent's book this row belongs to. Comes from the
--                      device session, never from the request body — a client
--                      cannot write into someone else's book by asking.
--
--   updated_at         SERVER clock. The pull cursor. Clients' clocks drift,
--                      are wrong out of the box, and go backwards when the user
--                      fiddles with them; a cursor built on client time silently
--                      skips rows forever. This one is stamped by a trigger and
--                      the client is not allowed to set it.
--
--   client_updated_at  CLIENT clock. The conflict rule, and only that. When two
--                      devices touch the same row, the later *edit* should win,
--                      not whichever device happened to reconnect last — a phone
--                      that syncs after a week offline must not resurrect its
--                      week-old copy over yesterday's desktop edit. Compared
--                      only against another client_updated_at, never used to
--                      decide what to send.
--
--   deleted            tombstone. A delete has to travel: an undone collection
--                      is money the agent says he did not take, and if that
--                      never reaches the other device the two disagree about
--                      cash. Rows are never hard-deleted by sync.
--
--   origin_device      which device last wrote the row. Purely an echo guard:
--                      pull skips rows the caller itself wrote, so the first
--                      sync of a 1,500-account book does not immediately
--                      download that same book back. Never a security boundary
--                      — account_id is. If it is wrong the worst case is a
--                      redundant round trip.
-- ---------------------------------------------------------------------------

-- Stamps `updated_at` on every write. Attached to all three tables below.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Accounts — the agent's customers.
-- ---------------------------------------------------------------------------
-- Mirrors `accounts` in the device schema. The natural key is the RD account
-- number, which the portal guarantees unique per agent, so no client uuid is
-- needed here and a re-sync on either device converges on the same rows.
--
-- Both kinds of column live side by side and that is the point:
--   * portal-derived (name, denomination, due date, months paid, ...) — a full
--     Sync overwrites these wholesale.
--   * agent-local (route_order, daily_amount, aslaas, status) — the portal has
--     never heard of them, and a Sync must preserve them. The device repository
--     already protects them in `replaceAll`; the server keeps them so a fresh
--     desktop login gets the agent's walking order, not a blank one.
-- ---------------------------------------------------------------------------
create table if not exists public.book_accounts (
  account_id            uuid not null references public.accounts(id) on delete cascade,
  account_number        text not null,

  customer_name         text not null default '',
  denomination_amount   bigint not null default 0,
  next_due_date         text,            -- ISO date, stored as the device does
  months_paid           int  not null default 0,
  serial                int  not null default 0,
  status                text not null default 'pending',
  aslaas                text,
  opening_date          text,
  total_deposit         bigint,
  pending_installments  int,
  default_installments  int,
  last_deposit_date     text,
  route_order           int,
  daily_amount          bigint,
  closed_at             text,

  deleted               boolean     not null default false,
  origin_device     text,
  client_updated_at     timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  primary key (account_id, account_number)
);

-- ---------------------------------------------------------------------------
-- Collections — the money ledger.
-- ---------------------------------------------------------------------------
-- The one table where getting sync wrong costs an agent real rupees, so it is
-- the one table that does not use an auto-increment id.
--
-- On the device `collections.id` is INTEGER AUTOINCREMENT. Two devices both
-- issue id 41 on the same afternoon for two different handovers, and any
-- merge keyed on that id destroys one of them. `uid` is a client-generated
-- uuid v4: it collides with nothing, so a merge is a union and no handover can
-- be lost by two agents' devices being used the same day.
--
-- Append-only in spirit. The only mutation is `deleted` (the Undo on the
-- collect row) and the rare edit that moves an entry to today.
-- ---------------------------------------------------------------------------
create table if not exists public.book_collections (
  account_id        uuid not null references public.accounts(id) on delete cascade,
  uid               text not null,             -- client uuid v4, stable forever

  account_number    text    not null,
  amount            bigint  not null,
  installments      int     not null default 1,
  collected_at      text    not null,          -- ISO datetime from the device
  cycle_ym          text    not null,          -- 'YYYY-MM', the collection cycle
  note              text,

  deleted           boolean     not null default false,
  origin_device     text,
  client_updated_at timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  primary key (account_id, uid)
);

-- The two reads the app ever does: "this cycle" and "this customer's history".
create index if not exists idx_book_collections_cycle
  on public.book_collections (account_id, cycle_ym) where not deleted;
create index if not exists idx_book_collections_account
  on public.book_collections (account_id, account_number, cycle_ym) where not deleted;

-- ---------------------------------------------------------------------------
-- Lots — saved lists.
-- ---------------------------------------------------------------------------
-- Same uuid reasoning as collections. `items_json` is carried opaquely: it is
-- the device's own encoding of the list and the server has no business parsing
-- it. `item_count` and `total_amount` are denormalised alongside it so the
-- desktop can list lots without decoding every blob, exactly as `v_lots` does
-- on the device.
-- ---------------------------------------------------------------------------
create table if not exists public.book_lots (
  account_id        uuid not null references public.accounts(id) on delete cascade,
  uid               text not null,             -- client uuid v4

  created_at        text not null,             -- ISO datetime from the device
  mode              text not null,             -- cash | cheque | ndc ...
  items_json        text not null,
  reference_number  text,                      -- C…/DC…/NDC… once submitted
  submitted_at      text,
  item_count        int    not null default 0,
  total_amount      bigint not null default 0,

  deleted           boolean     not null default false,
  origin_device     text,
  client_updated_at timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  primary key (account_id, uid)
);

create index if not exists idx_book_lots_created
  on public.book_lots (account_id, created_at desc) where not deleted;

-- ---------------------------------------------------------------------------
-- Pull cursors
-- ---------------------------------------------------------------------------
-- Every pull is "rows for this account changed since T". Without these three
-- indexes that is a sequential scan of the agent's whole book on every sync,
-- which is fine at 200 accounts and not fine at 1,500.
-- ---------------------------------------------------------------------------
create index if not exists idx_book_accounts_cursor
  on public.book_accounts (account_id, updated_at);
create index if not exists idx_book_collections_cursor
  on public.book_collections (account_id, updated_at);
create index if not exists idx_book_lots_cursor
  on public.book_lots (account_id, updated_at);

drop trigger if exists trg_book_accounts_touch on public.book_accounts;
create trigger trg_book_accounts_touch before insert or update
  on public.book_accounts for each row execute function public.touch_updated_at();

drop trigger if exists trg_book_collections_touch on public.book_collections;
create trigger trg_book_collections_touch before insert or update
  on public.book_collections for each row execute function public.touch_updated_at();

drop trigger if exists trg_book_lots_touch on public.book_lots;
create trigger trg_book_lots_touch before insert or update
  on public.book_lots for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: on, and deliberately empty.
-- ---------------------------------------------------------------------------
-- No policies means no anon access at all. The `sync` edge function holds the
-- service role key and is the only path in. This is the same posture as
-- device_sessions / otp_codes in schema_otp.sql.
-- ---------------------------------------------------------------------------
alter table public.book_accounts    enable row level security;
alter table public.book_collections enable row level security;
alter table public.book_lots        enable row level security;

-- ---------------------------------------------------------------------------
-- Admin read-only summary (service_role; the dashboard's Users tab).
-- ---------------------------------------------------------------------------
-- Counts only. The dashboard has no reason to read a customer's name, and this
-- view is what it should reach for instead of the tables.
-- ---------------------------------------------------------------------------
create or replace view public.v_book_summary as
  select
    a.id                                  as account_id,
    a.agent_id,
    (select count(*) from public.book_accounts    b
       where b.account_id = a.id and not b.deleted) as accounts,
    (select count(*) from public.book_collections c
       where c.account_id = a.id and not c.deleted) as collections,
    (select count(*) from public.book_lots        l
       where l.account_id = a.id and not l.deleted) as lots,
    greatest(
      coalesce((select max(updated_at) from public.book_accounts    b where b.account_id = a.id), 'epoch'),
      coalesce((select max(updated_at) from public.book_collections c where c.account_id = a.id), 'epoch'),
      coalesce((select max(updated_at) from public.book_lots        l where l.account_id = a.id), 'epoch')
    )                                     as last_write
  from public.accounts a;

-- ============================================================================
-- Sync RPCs
-- ----------------------------------------------------------------------------
-- The `sync` edge function is a thin wrapper around these six. Both halves of
-- sync have a correctness rule that is only safe inside the database, so
-- neither is written in TypeScript:
--
--   PUSH  the last-write-wins comparison and the write must be one atomic
--         statement. Read-then-write from the function is a race: two devices
--         pushing the same collection interleave, both read "older", both
--         write, and the loser's version survives. `on conflict ... where`
--         makes the comparison part of the write itself.
--
--   PULL  the cursor is composite — (updated_at, key), not updated_at alone.
--         A first full push upserts 1,500 accounts inside ONE transaction, so
--         all 1,500 rows share a single `now()`. A cursor of "updated_at >
--         last seen" then skips every row after the first page, permanently.
--         Paging on the pair is the fix, and PostgREST cannot express the
--         row-value comparison it needs.
--
-- All six are called with p_account_id resolved from the caller's device
-- session. The account id NEVER comes from the request body — see sync/index.ts.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- PUSH
-- ---------------------------------------------------------------------------
-- Returns the number of rows actually written, which is not the number sent:
-- a push that loses the client_updated_at comparison is silently a no-op, and
-- that is the correct outcome, not an error. The count is for the dashboard and
-- for the client's own logs.
-- ---------------------------------------------------------------------------

create or replace function public.book_push_accounts(p_account_id uuid, p_rows jsonb, p_device text default null)
returns int language plpgsql as $$
declare n int;
begin
  -- `distinct on` is not tidiness. Postgres raises "ON CONFLICT DO UPDATE
  -- command cannot affect row a second time" the moment one batch carries the
  -- same key twice, which aborts the whole push — and a client that resent a
  -- row (a retry, a double tap) would then be unable to sync anything, ever,
  -- until someone noticed. Keep the newest edit of each key and drop the rest.
  with src as (
    select distinct on (r.account_number) r.*
    from jsonb_to_recordset(p_rows) as r(
      account_number text, customer_name text, denomination_amount bigint,
      next_due_date text, months_paid int, serial int, status text,
      aslaas text, opening_date text, total_deposit bigint,
      pending_installments int, default_installments int,
      last_deposit_date text, route_order int, daily_amount bigint,
      closed_at text, deleted boolean, client_updated_at timestamptz
    )
    where r.account_number is not null and r.account_number <> ''
    order by r.account_number, r.client_updated_at desc nulls last
  )
  insert into public.book_accounts as t (
    account_id, account_number, customer_name, denomination_amount,
    next_due_date, months_paid, serial, status, aslaas, opening_date,
    total_deposit, pending_installments, default_installments,
    last_deposit_date, route_order, daily_amount, closed_at,
    deleted, client_updated_at, origin_device
  )
  select
    p_account_id, r.account_number, coalesce(r.customer_name, ''),
    coalesce(r.denomination_amount, 0), r.next_due_date,
    coalesce(r.months_paid, 0), coalesce(r.serial, 0),
    coalesce(r.status, 'pending'), r.aslaas, r.opening_date,
    r.total_deposit, r.pending_installments, r.default_installments,
    r.last_deposit_date, r.route_order, r.daily_amount, r.closed_at,
    coalesce(r.deleted, false), coalesce(r.client_updated_at, now()), p_device
  from src r
  on conflict (account_id, account_number) do update set
    customer_name        = excluded.customer_name,
    denomination_amount  = excluded.denomination_amount,
    next_due_date        = excluded.next_due_date,
    months_paid          = excluded.months_paid,
    serial               = excluded.serial,
    status               = excluded.status,
    aslaas               = excluded.aslaas,
    opening_date         = excluded.opening_date,
    total_deposit        = excluded.total_deposit,
    pending_installments = excluded.pending_installments,
    default_installments = excluded.default_installments,
    last_deposit_date    = excluded.last_deposit_date,
    route_order          = excluded.route_order,
    daily_amount         = excluded.daily_amount,
    closed_at            = excluded.closed_at,
    deleted              = excluded.deleted,
    client_updated_at    = excluded.client_updated_at,
    origin_device        = excluded.origin_device
  where excluded.client_updated_at >= t.client_updated_at;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.book_push_collections(p_account_id uuid, p_rows jsonb, p_device text default null)
returns int language plpgsql as $$
declare n int;
begin
  with src as (
    select distinct on (r.uid) r.*
    from jsonb_to_recordset(p_rows) as r(
      uid text, account_number text, amount bigint, installments int,
      collected_at text, cycle_ym text, note text,
      deleted boolean, client_updated_at timestamptz
    )
    where r.uid is not null and r.uid <> ''
      and r.account_number is not null
      and r.amount is not null
      and r.collected_at is not null
      and r.cycle_ym is not null
    order by r.uid, r.client_updated_at desc nulls last
  )
  insert into public.book_collections as t (
    account_id, uid, account_number, amount, installments,
    collected_at, cycle_ym, note, deleted, client_updated_at, origin_device
  )
  select
    p_account_id, r.uid, r.account_number, r.amount,
    coalesce(r.installments, 1), r.collected_at, r.cycle_ym, r.note,
    coalesce(r.deleted, false), coalesce(r.client_updated_at, now()), p_device
  from src r
  on conflict (account_id, uid) do update set
    account_number    = excluded.account_number,
    amount            = excluded.amount,
    installments      = excluded.installments,
    collected_at      = excluded.collected_at,
    cycle_ym          = excluded.cycle_ym,
    note              = excluded.note,
    deleted           = excluded.deleted,
    client_updated_at = excluded.client_updated_at,
    origin_device     = excluded.origin_device
  where excluded.client_updated_at >= t.client_updated_at;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.book_push_lots(p_account_id uuid, p_rows jsonb, p_device text default null)
returns int language plpgsql as $$
declare n int;
begin
  with src as (
    select distinct on (r.uid) r.*
    from jsonb_to_recordset(p_rows) as r(
      uid text, created_at text, mode text, items_json text,
      reference_number text, submitted_at text, item_count int,
      total_amount bigint, deleted boolean, client_updated_at timestamptz
    )
    where r.uid is not null and r.uid <> '' and r.created_at is not null
    order by r.uid, r.client_updated_at desc nulls last
  )
  insert into public.book_lots as t (
    account_id, uid, created_at, mode, items_json, reference_number,
    submitted_at, item_count, total_amount, deleted, client_updated_at, origin_device
  )
  select
    p_account_id, r.uid, r.created_at, coalesce(r.mode, 'cash'),
    coalesce(r.items_json, '[]'), r.reference_number, r.submitted_at,
    coalesce(r.item_count, 0), coalesce(r.total_amount, 0),
    coalesce(r.deleted, false), coalesce(r.client_updated_at, now()), p_device
  from src r
  on conflict (account_id, uid) do update set
    created_at        = excluded.created_at,
    mode              = excluded.mode,
    items_json        = excluded.items_json,
    reference_number  = excluded.reference_number,
    submitted_at      = excluded.submitted_at,
    item_count        = excluded.item_count,
    total_amount      = excluded.total_amount,
    deleted           = excluded.deleted,
    client_updated_at = excluded.client_updated_at,
    origin_device     = excluded.origin_device
  where excluded.client_updated_at >= t.client_updated_at;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- PULL
-- ---------------------------------------------------------------------------
-- p_since / p_key are the composite cursor. First ever pull passes
-- ('epoch', '') and gets the whole book, one page at a time.
--
-- `(t.updated_at, t.key) > (p_since, p_key)` is a row-value comparison: it
-- reads every row at the cursor's timestamp whose key sorts after the last one
-- seen, then everything later. That is what makes a 1,500-row bulk write —
-- all sharing one transaction timestamp — page correctly instead of being
-- truncated to the first page forever.
--
-- Tombstones ARE returned. A deleted row that never travels is a collection the
-- agent undid on his phone and still sees on the desktop.
-- ---------------------------------------------------------------------------

create or replace function public.book_pull_accounts(
  p_account_id uuid, p_since timestamptz, p_key text, p_limit int default 1000,
  p_device text default null)
returns setof public.book_accounts language sql stable as $$
  select * from public.book_accounts t
  where t.account_id = p_account_id
    and (t.updated_at, t.account_number) > (p_since, p_key)
    and (p_device is null or t.origin_device is distinct from p_device)
  order by t.updated_at, t.account_number
  limit least(greatest(p_limit, 1), 5000);
$$;

create or replace function public.book_pull_collections(
  p_account_id uuid, p_since timestamptz, p_key text, p_limit int default 1000,
  p_device text default null)
returns setof public.book_collections language sql stable as $$
  select * from public.book_collections t
  where t.account_id = p_account_id
    and (t.updated_at, t.uid) > (p_since, p_key)
    and (p_device is null or t.origin_device is distinct from p_device)
  order by t.updated_at, t.uid
  limit least(greatest(p_limit, 1), 5000);
$$;

create or replace function public.book_pull_lots(
  p_account_id uuid, p_since timestamptz, p_key text, p_limit int default 1000,
  p_device text default null)
returns setof public.book_lots language sql stable as $$
  select * from public.book_lots t
  where t.account_id = p_account_id
    and (t.updated_at, t.uid) > (p_since, p_key)
    and (p_device is null or t.origin_device is distinct from p_device)
  order by t.updated_at, t.uid
  limit least(greatest(p_limit, 1), 5000);
$$;

-- ---------------------------------------------------------------------------
-- Only the edge function may call these.
-- ---------------------------------------------------------------------------
-- They take p_account_id as an argument, so anyone who could call them
-- directly could read any agent's book by guessing a uuid. service_role only —
-- the anon key must not reach them even by name.
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.book_push_accounts(uuid, jsonb, text)',
    'public.book_push_collections(uuid, jsonb, text)',
    'public.book_push_lots(uuid, jsonb, text)',
    'public.book_pull_accounts(uuid, timestamptz, text, int, text)',
    'public.book_pull_collections(uuid, timestamptz, text, int, text)',
    'public.book_pull_lots(uuid, timestamptz, text, int, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;
