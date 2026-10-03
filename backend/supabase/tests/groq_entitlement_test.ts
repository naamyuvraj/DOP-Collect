// Entitlement enforcement in the `groq` proxy (P5).
//
// The paywall in the app is a client gate that fails open on purpose, so the
// paid capability that actually costs money to serve checks the subscription
// here too. These tests exist mostly to pin down what it must NOT do: it is
// dormant until payments_enabled is on, and it refuses only an agent it can
// positively identify as expired. Everything else — no token, an unknown token,
// no subscription row — is served, because "we can't tell" must never read as
// "no".

import { assertEquals } from "jsr:@std/assert@1";
import { type Db, newDb } from "./mock_supabase.ts";
import { BASE_ENV, begin, load, post, sha256Hex } from "./harness.ts";

const AGENT = "AGENT-MINE-01";
const MY_TOKEN = "my-live-token";

const handler = await load("groq");

/** A working proxy: one Groq key, and Groq itself answering normally. */
async function seeded(): Promise<Db> {
  const db = newDb();
  const account = crypto.randomUUID();
  db.tables.accounts.push({
    id: account, agent_id: AGENT, phone_hash: "h1", disabled: false,
  });
  db.tables.device_sessions.push({
    id: crypto.randomUUID(), account_id: account, device_id: "d1",
    token_hash: await sha256Hex(MY_TOKEN), revoked_at: null,
  });
  db.tables.app_keys = [{ id: 1, provider: "groq", key: "gsk_test", enabled: true }];
  return db;
}

const GROQ_OK = {
  status: 200,
  json: { choices: [{ message: { content: "hello" } }] },
};

function start(db: Db) {
  begin(db, { env: BASE_ENV, reply: () => GROQ_OK });
}

const ask = (body: Record<string, unknown> = {}) =>
  post(handler, { system: "s", user: "u", ...body });

/** An expired subscription for our agent. */
function expired(db: Db) {
  db.tables.subscriptions.push({
    agent_id: AGENT, plan_code: "m1", status: "active",
    current_period_end: new Date(Date.now() - 5 * 86400_000).toISOString(),
  });
}

const paymentsOn = (db: Db) =>
  db.tables.app_config.push({ key: "payments_enabled", value: true });

// ---------------------------------------------------------------------------
// Dormant until launch
// ---------------------------------------------------------------------------

Deno.test("P5: with payments OFF, an expired agent is still served", async () => {
  const db = await seeded();
  expired(db); // payments_enabled absent => the whole gate is inert
  start(db);
  const res = await ask({ token: MY_TOKEN });
  assertEquals(res.status, 200);
  assertEquals(res.json.content, "hello");
});

// ---------------------------------------------------------------------------
// With payments on: refuse only what we can positively identify as expired
// ---------------------------------------------------------------------------

Deno.test("P5: an expired agent is refused server-side", async () => {
  const db = await seeded();
  paymentsOn(db);
  expired(db);
  start(db);

  const res = await ask({ token: MY_TOKEN });
  assertEquals(res.status, 402);
  assertEquals(res.json.error, "subscription_expired");
});

Deno.test("P5: an agent with time left is served", async () => {
  const db = await seeded();
  paymentsOn(db);
  db.tables.subscriptions.push({
    agent_id: AGENT, plan_code: "m1", status: "active",
    current_period_end: new Date(Date.now() + 20 * 86400_000).toISOString(),
  });
  start(db);

  const res = await ask({ token: MY_TOKEN });
  assertEquals(res.status, 200);
  assertEquals(res.json.content, "hello");
});

Deno.test("P5: no token means 'we don't know who this is' — serve it", async () => {
  const db = await seeded();
  paymentsOn(db);
  expired(db);
  start(db);

  // Same expired agent, but nothing identifies them. Refusing here would break
  // every install that hasn't verified a phone yet.
  const res = await ask();
  assertEquals(res.status, 200);
  assertEquals(res.json.content, "hello");
});

Deno.test("P5: an unknown or revoked token is not treated as a rejection", async () => {
  const db = await seeded();
  paymentsOn(db);
  expired(db);
  start(db);
  assertEquals((await ask({ token: "never-issued" })).status, 200);

  const db2 = await seeded();
  paymentsOn(db2);
  expired(db2);
  db2.tables.device_sessions[0].revoked_at = new Date().toISOString();
  start(db2);
  assertEquals((await ask({ token: MY_TOKEN })).status, 200);
});

Deno.test("P5: an agent with no subscription row at all is served", async () => {
  const db = await seeded();
  paymentsOn(db); // identified, but nothing has granted them anything yet
  start(db);

  const res = await ask({ token: MY_TOKEN });
  assertEquals(res.status, 200);
  assertEquals(res.json.content, "hello");
});

Deno.test("P5: an expiry later today still counts as access", async () => {
  const db = await seeded();
  paymentsOn(db);
  db.tables.subscriptions.push({
    agent_id: AGENT, plan_code: "m1", status: "active",
    current_period_end: new Date(Date.now() + 60_000).toISOString(),
  });
  start(db);

  assertEquals((await ask({ token: MY_TOKEN })).status, 200, "a minute of access is access");
});
