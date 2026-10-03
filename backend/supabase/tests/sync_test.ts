// API tests for the `sync` edge function, driving the real handler.
//
// SCOPE — read this before adding a test here.
//
// The rules that make sync *correct* (last-write-wins, the composite pull
// cursor, in-batch dedupe, agent isolation at the row level) are PL/pgSQL and
// are tested against a real Postgres in book_sql_test.sql. Re-checking them
// through a TypeScript double would only prove the double agrees with itself.
//
// What this file tests is what the FUNCTION owns and the database cannot:
//
//   * whose book gets touched — always the session's account, never the body's
//   * which device is credited with a write — the session's, never the body's
//   * refusing revoked / unknown / disabled sessions
//   * the request caps, and turning a page of rows into the next cursor
//
// The book_* RPCs are therefore stubs that record their arguments and return
// canned rows.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Db, newDb } from "./mock_supabase.ts";
import { BASE_ENV, begin, load, post, sha256Hex } from "./harness.ts";

const handler = await load("sync");

const TOKEN = "live-session-token";
const DEVICE = "phone-abc";
const OTHER_DEVICE = "desktop-xyz";

/** Rows the pull stubs hand back, set per test. */
type Rows = Record<string, Record<string, unknown>[]>;

interface Seeded {
  db: Db;
  accountId: string;
  /** Every book_push_* / book_pull_* call the function made. */
  calls: { name: string; args: Record<string, unknown> }[];
}

async function seeded(
  opts: { disabled?: boolean; revoked?: boolean; pull?: Rows } = {},
): Promise<Seeded> {
  const db = newDb();
  const accountId = crypto.randomUUID();
  const calls: Seeded["calls"] = [];

  db.tables.accounts.push({
    id: accountId,
    agent_id: "AGENT-01",
    disabled: opts.disabled ?? false,
  });
  db.tables.device_sessions.push({
    id: crypto.randomUUID(),
    account_id: accountId,
    device_id: DEVICE,
    token_hash: await sha256Hex(TOKEN),
    revoked_at: opts.revoked ? new Date().toISOString() : null,
    revoked_reason: opts.revoked ? "device_limit" : null,
    last_seen: "2020-01-01T00:00:00.000Z",
  });

  const pull = opts.pull ?? {};
  db.rpcHandlers = {};
  for (const t of ["accounts", "collections", "lots"]) {
    db.rpcHandlers[`book_push_${t}`] = (args) => {
      calls.push({ name: `book_push_${t}`, args });
      return (args.p_rows as unknown[]).length;
    };
    db.rpcHandlers[`book_pull_${t}`] = (args) => {
      calls.push({ name: `book_pull_${t}`, args });
      return pull[t] ?? [];
    };
  }

  begin(db, { env: BASE_ENV });
  return { db, accountId, calls };
}

const call = (calls: Seeded["calls"], name: string) =>
  calls.find((c) => c.name === name)!;

// ---------------------------------------------------------------------------
// Session is the only source of identity
// ---------------------------------------------------------------------------

Deno.test("a request with no token is refused", async () => {
  await seeded();
  const { status, json } = await post(handler, {});
  assertEquals(status, 403);
  assertEquals(json.code, "no_session");
});

Deno.test("an unknown token is refused", async () => {
  await seeded();
  const { status, json } = await post(handler, { token: "not-a-real-token" });
  assertEquals(status, 403);
  assertEquals(json.code, "no_session");
});

Deno.test("a revoked session is refused, and says why", async () => {
  // This is how a device kicked by the 2-device limit finds out: its next sync
  // comes back no_session, and the app signs itself out.
  await seeded({ revoked: true });
  const { status, json } = await post(handler, { token: TOKEN });
  assertEquals(status, 403);
  assertEquals(json.code, "no_session");
  assertEquals(json.reason, "device_limit");
});

Deno.test("a disabled agent moves no data in either direction", async () => {
  const { calls } = await seeded({ disabled: true });
  const { status, json } = await post(handler, {
    token: TOKEN,
    push: { accounts: [{ account_number: "1" }] },
  });
  assertEquals(status, 403);
  assertEquals(json.code, "disabled");
  assertEquals(calls.length, 0, "a disabled agent must not reach the book");
});

Deno.test("the account id comes from the session, never from the body", async () => {
  // The whole security model. If the body could name the book, knowing (or
  // guessing) another agent's uuid would be enough to read and overwrite it.
  const { accountId, calls } = await seeded();
  const foreign = crypto.randomUUID();
  const { status } = await post(handler, {
    token: TOKEN,
    accountId: foreign,
    account_id: foreign,
    push: { accounts: [{ account_number: "1", customer_name: "x" }] },
  });
  assertEquals(status, 200);
  for (const c of calls) {
    assertEquals(c.args.p_account_id, accountId, `${c.name} used the wrong book`);
  }
});

Deno.test("the writing device comes from the session, never from the body", async () => {
  // The echo guard keys on this. A client that could name any device id could
  // suppress the other device's pull by claiming to be it.
  const { calls } = await seeded();
  await post(handler, {
    token: TOKEN,
    device: OTHER_DEVICE,
    deviceId: OTHER_DEVICE,
    push: { lots: [{ uid: "u1", created_at: "2026-08-30T00:00:00Z" }] },
  });
  for (const c of calls) {
    assertEquals(c.args.p_device, DEVICE, `${c.name} credited the wrong device`);
  }
});

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------

Deno.test("push happens before pull, so a write is merged in the same round trip", async () => {
  const { calls } = await seeded();
  await post(handler, {
    token: TOKEN,
    push: { collections: [{ uid: "u1", amount: 100 }] },
  });
  const pushAt = calls.findIndex((c) => c.name === "book_push_collections");
  const pullAt = calls.findIndex((c) => c.name === "book_pull_collections");
  assert(pushAt >= 0 && pullAt >= 0);
  assert(pushAt < pullAt, "pull ran before push");
});

Deno.test("an empty or absent push touches no push RPC", async () => {
  const { calls } = await seeded();
  await post(handler, { token: TOKEN, push: { accounts: [], collections: [] } });
  assert(!calls.some((c) => c.name.startsWith("book_push_")));
});

Deno.test("an oversized batch is refused with the cap, not silently truncated", async () => {
  // Truncating would drop collections — money — with a 200 OK. The client is
  // told the limit so it can chunk and retry.
  const { calls } = await seeded();
  const rows = Array.from({ length: 2001 }, (_, i) => ({ uid: `u${i}`, amount: 1 }));
  const { status, json } = await post(handler, {
    token: TOKEN,
    push: { collections: rows },
  });
  assertEquals(status, 413);
  assertEquals(json.code, "too_many");
  assertEquals(json.table, "collections");
  assertEquals(json.max, 2000);
  assertEquals(json.sent, 2001);
  assert(!calls.some((c) => c.name.startsWith("book_push_")), "wrote anyway");
});

Deno.test("exactly the cap is accepted", async () => {
  const { calls } = await seeded();
  const rows = Array.from({ length: 2000 }, (_, i) => ({ uid: `u${i}`, amount: 1 }));
  const { status, json } = await post(handler, {
    token: TOKEN,
    push: { collections: rows },
  });
  assertEquals(status, 200);
  assertEquals((json.pushed as Record<string, number>).collections, 2000);
  assertEquals((call(calls, "book_push_collections").args.p_rows as unknown[]).length, 2000);
});

Deno.test("a push RPC failure is reported, not swallowed as success", async () => {
  const { db } = await seeded();
  db.rpcHandlers!.book_push_lots = () => ({ error: { message: "boom" } });
  const { status, json } = await post(handler, {
    token: TOKEN,
    push: { lots: [{ uid: "u1", created_at: "2026-08-30T00:00:00Z" }] },
  });
  assertEquals(status, 500);
  assertEquals(json.code, "push_failed");
  assertEquals(json.table, "lots");
});

// ---------------------------------------------------------------------------
// Pull cursor
// ---------------------------------------------------------------------------

Deno.test("the cursor advances to the LAST row of the page, not to now()", async () => {
  // The rows past this page may share its timestamp — a first full sync writes
  // the whole book under one transaction clock. Only the (updated_at, key) pair
  // separates them, so the cursor has to be the last row itself.
  const shared = "2026-08-30T10:00:00.000Z";
  await seeded({
    pull: {
      accounts: [
        { account_number: "0001", updated_at: shared },
        { account_number: "0002", updated_at: shared },
        { account_number: "0003", updated_at: shared },
      ],
    },
  });
  const res = await post(handler, { token: TOKEN, limit: 3 });
  const cursor = (res.json.cursor as Record<string, { t: string; k: string }>);
  assertEquals(cursor.accounts.t, shared);
  assertEquals(cursor.accounts.k, "0003", "cursor did not land on the last row");
});

Deno.test("a full page sets more, a short page does not", async () => {
  await seeded({
    pull: { lots: [{ uid: "a", updated_at: "2026-08-30T10:00:00.000Z" }] },
  });
  const full = await post(handler, { token: TOKEN, limit: 1 });
  assertEquals(full.json.more, true, "a page at the limit means keep going");

  await seeded({
    pull: { lots: [{ uid: "a", updated_at: "2026-08-30T10:00:00.000Z" }] },
  });
  const short = await post(handler, { token: TOKEN, limit: 10 });
  assertEquals(short.json.more, false);
});

Deno.test("an empty page leaves the cursor exactly where it was", async () => {
  // Nothing changed upstream, so the client must not lose its place — and must
  // not skip forward over rows written between this call and the next.
  await seeded();
  const cur = { t: "2026-08-30T10:00:00.000Z", k: "0042" };
  const { json } = await post(handler, {
    token: TOKEN,
    cursor: { accounts: cur, collections: cur, lots: cur },
  });
  const out = json.cursor as Record<string, { t: string; k: string }>;
  assertEquals(out.accounts, cur);
  assertEquals(out.collections, cur);
  assertEquals(out.lots, cur);
});

Deno.test("the incoming cursor is passed through to the pull RPC", async () => {
  const { calls } = await seeded();
  await post(handler, {
    token: TOKEN,
    cursor: { collections: { t: "2026-08-30T10:00:00.000Z", k: "u9" } },
  });
  const args = call(calls, "book_pull_collections").args;
  assertEquals(args.p_since, "2026-08-30T10:00:00.000Z");
  assertEquals(args.p_key, "u9");
});

Deno.test("a malformed cursor falls back to a full re-pull instead of failing forever", async () => {
  // A cursor the database cannot parse would throw on every sync from here on,
  // and the client has no way to repair a value it also cannot read. Expensive
  // once beats broken permanently.
  const { calls } = await seeded();
  await post(handler, {
    token: TOKEN,
    cursor: { accounts: { t: "not-a-timestamp", k: 42 } },
  });
  const args = call(calls, "book_pull_accounts").args;
  assertEquals(args.p_since, "1970-01-01T00:00:00.000Z");
  assertEquals(args.p_key, "");
});

Deno.test("a missing cursor pulls the whole book", async () => {
  const { calls } = await seeded();
  await post(handler, { token: TOKEN });
  for (const t of ["accounts", "collections", "lots"]) {
    const args = call(calls, `book_pull_${t}`).args;
    assertEquals(args.p_since, "1970-01-01T00:00:00.000Z");
    assertEquals(args.p_key, "");
  }
});

Deno.test("the page limit is clamped to the server's maximum", async () => {
  const { calls } = await seeded();
  await post(handler, { token: TOKEN, limit: 999999 });
  assertEquals(call(calls, "book_pull_accounts").args.p_limit, 5000);
});

Deno.test("a nonsense limit falls back to the default", async () => {
  const { calls } = await seeded();
  await post(handler, { token: TOKEN, limit: -5 });
  assertEquals(call(calls, "book_pull_accounts").args.p_limit, 1000);
});

Deno.test("a pull RPC failure is reported, not returned as an empty book", async () => {
  // An empty book and a failed read look identical to the client unless we say
  // so — and "your accounts are gone" is the worst possible way to be wrong.
  const { db } = await seeded();
  db.rpcHandlers!.book_pull_accounts = () => ({ error: { message: "boom" } });
  const { status, json } = await post(handler, { token: TOKEN });
  assertEquals(status, 500);
  assertEquals(json.code, "pull_failed");
  assertEquals(json.table, "accounts");
});

// ---------------------------------------------------------------------------
// Housekeeping
// ---------------------------------------------------------------------------

Deno.test("a successful sync refreshes the session's last_seen", async () => {
  // More reliable than the app-open heartbeat, which a backgrounded phone
  // never sends — this is what the dashboard's device list should trust.
  const { db } = await seeded();
  await post(handler, { token: TOKEN });
  const seen = String(db.tables.device_sessions[0].last_seen);
  assert(seen > "2020-01-01T00:00:00.000Z", `last_seen not refreshed: ${seen}`);
});

Deno.test("sync is rate limited per device", async () => {
  const { db } = await seeded();
  db.counters[`sync:${DEVICE}`] = 240;
  const { status, json } = await post(handler, { token: TOKEN });
  assertEquals(status, 429);
  assertEquals(json.code, "rate");
});

Deno.test("GET is refused", async () => {
  await seeded();
  const res = await handler(new Request("https://fn.test/", { method: "GET" }));
  assertEquals(res.status, 405);
});

Deno.test("preflight is answered for the browser", async () => {
  // The desktop app is a web page on another origin; without this it cannot
  // call sync at all.
  await seeded();
  const res = await handler(new Request("https://fn.test/", { method: "OPTIONS" }));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
});
