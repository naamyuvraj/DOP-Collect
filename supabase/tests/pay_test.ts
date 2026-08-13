// API tests for the `pay` edge function, driving the real handler.
//
// Focus: S7 (identity must come from the session, not a claimed agent id) and
// F5 (only a genuine duplicate may be reported as "already processed").

import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Db, newDb } from "./mock_supabase.ts";
import { BASE_ENV, begin, load, post, sha256Hex } from "./harness.ts";

const ENV = {
  ...BASE_ENV,
  RAZORPAY_KEY_ID: "rzp_test_key",
  RAZORPAY_KEY_SECRET: "rzp_test_secret",
};

const MINE = "AGENT-MINE-01";
const THEIRS = "AGENT-THEIRS-02";
const MY_TOKEN = "my-live-token";

const handler = await load("pay");

async function seeded(): Promise<Db> {
  const db = newDb();
  const myAccount = crypto.randomUUID();
  const theirAccount = crypto.randomUUID();
  db.tables.accounts.push(
    { id: myAccount, agent_id: MINE, phone_hash: "h1", disabled: false },
    { id: theirAccount, agent_id: THEIRS, phone_hash: "h2", disabled: false },
  );
  db.tables.device_sessions.push({
    id: crypto.randomUUID(), account_id: myAccount, device_id: "d1",
    token_hash: await sha256Hex(MY_TOKEN), revoked_at: null,
    created_at: new Date().toISOString(),
  });
  db.tables.plans.push(
    { code: "m1", name: "Monthly", price_inr: 199, duration_days: 30, active: true, sort: 1 },
    { code: "y1", name: "Yearly", price_inr: 1499, duration_days: 365, active: true, sort: 2 },
  );
  // A neighbour's paid-up subscription — the thing S7 must not disclose.
  db.tables.subscriptions.push({
    agent_id: THEIRS, plan_code: "y1", status: "active",
    current_period_end: new Date(Date.now() + 300 * 86400_000).toISOString(),
  });
  db.tables.app_config.push({ key: "payments_enabled", value: true });
  return db;
}

// ---------------------------------------------------------------------------
// S7 — identity comes from the session
// ---------------------------------------------------------------------------

Deno.test("S7: status without a token is refused", async () => {
  begin(await seeded(), { env: ENV });
  const res = await post(handler, { action: "status", agentId: THEIRS });
  assertEquals(res.status, 401);
  assertEquals(res.json.error, "unauthorized");
  assertEquals(res.json.planCode, undefined, "no plan may leak");
  assertEquals(res.json.periodEnd, undefined, "no expiry may leak");
});

Deno.test("S7: a valid token cannot read ANOTHER agent's subscription", async () => {
  begin(await seeded(), { env: ENV });
  // My token, but I claim their agent id.
  const res = await post(handler, { action: "status", agentId: THEIRS, token: MY_TOKEN });
  assertEquals(res.status, 200);
  assertEquals(res.json.ok, true);
  // Answered for ME — the claimed id was ignored, not honoured.
  assertEquals(res.json.planCode, "trial");
  assert(res.json.periodEnd !== undefined);
  const end = String(res.json.periodEnd);
  const theirEnd = new Date(Date.now() + 300 * 86400_000).toISOString().slice(0, 4);
  assert(
    !(String(res.json.planCode) === "y1" && end.startsWith(theirEnd)),
    "leaked the other agent's plan",
  );
});

Deno.test("S7: a revoked token is refused", async () => {
  const db = await seeded();
  db.tables.device_sessions[0].revoked_at = new Date().toISOString();
  begin(db, { env: ENV });
  const res = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(res.status, 401);
});

Deno.test("S7: a disabled account is refused", async () => {
  const db = await seeded();
  db.tables.accounts[0].disabled = true;
  begin(db, { env: ENV });
  const res = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(res.status, 401);
});

Deno.test("S7: my own status still works, and lists the plans", async () => {
  begin(await seeded(), { env: ENV });
  const res = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(res.status, 200);
  assertEquals(res.json.ok, true);
  assertEquals(res.json.status, "trial");
  assertEquals((res.json.plans as unknown[]).length, 2);
});

Deno.test("S7: an order is recorded against the SESSION's agent, not the claim", async () => {
  const db = await seeded();
  begin(db, {
    env: ENV,
    reply: (url) =>
      url.includes("razorpay")
        ? { status: 200, json: { id: "order_ABC", amount: 19900, currency: "INR" } }
        : { status: 200, json: {} },
  });
  const res = await post(handler, {
    action: "order", planCode: "m1", agentId: THEIRS, token: MY_TOKEN,
  });
  assertEquals(res.json.ok, true);
  assertEquals(res.json.orderId, "order_ABC");
  assertEquals(db.tables.orders.length, 1);
  assertEquals(db.tables.orders[0].agent_id, MINE, "order must belong to the session");
});

// ---------------------------------------------------------------------------
// F5 — "already processed" must mean a genuine duplicate
// ---------------------------------------------------------------------------

/** Razorpay's signature over `${orderId}|${paymentId}`. */
async function sign(secret: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const s = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(s)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function withOrder(): Promise<Db> {
  const db = await seeded();
  db.tables.orders.push({ order_id: "order_1", agent_id: MINE, plan_code: "m1", amount: 19900 });
  return db;
}

const verifyBody = async (o = "order_1", p = "pay_1") => ({
  action: "verify", orderId: o, paymentId: p, token: MY_TOKEN,
  signature: await sign(ENV.RAZORPAY_KEY_SECRET, `${o}|${p}`),
});

Deno.test("F5: a good payment activates the subscription", async () => {
  const db = await withOrder();
  begin(db, { env: ENV });
  const res = await post(handler, await verifyBody());
  assertEquals(res.status, 200);
  assertEquals(res.json.ok, true);
  assertEquals(res.json.status, "active");
  const sub = db.tables.subscriptions.find((s) => s.agent_id === MINE)!;
  assertEquals(sub.plan_code, "m1");
  assertEquals(sub.status, "active");
});

Deno.test("F5: a forged signature is refused", async () => {
  const db = await withOrder();
  begin(db, { env: ENV });
  const res = await post(handler, {
    action: "verify", orderId: "order_1", paymentId: "pay_1",
    signature: "deadbeef", token: MY_TOKEN,
  });
  assertEquals(res.status, 400);
  assertEquals(res.json.error, "bad_signature");
  assertEquals(db.tables.payments.length, 0);
});

Deno.test("F5: a replay is 'already', and does NOT extend twice", async () => {
  const db = await withOrder();
  begin(db, { env: ENV });
  const first = await post(handler, await verifyBody());
  const firstEnd = String(first.json.periodEnd);
  const again = await post(handler, await verifyBody());
  assertEquals(again.json.ok, true);
  assertEquals(again.json.note, "already_processed");
  assertEquals(again.json.periodEnd, firstEnd, "period must not move on a replay");
  assertEquals(db.tables.payments.length, 1);
});

Deno.test("F5: a NON-duplicate insert failure is reported as an error, not success", async () => {
  const db = await withOrder();
  // e.g. a missing column, an RLS change, a connection blip.
  db.failInsert = {
    table: "payments",
    error: { code: "42703", message: 'column "plan" does not exist' },
  };
  begin(db, { env: ENV });

  const res = await post(handler, await verifyBody());

  // The subscription was NOT extended, so the caller must not be told "ok".
  assertEquals(res.status, 400);
  assertEquals(res.json.ok, false);
  assertEquals(res.json.error, "record_failed");
  assertEquals(
    db.tables.subscriptions.find((s) => s.agent_id === MINE),
    undefined,
    "no entitlement should exist when the payment could not be recorded",
  );
});

Deno.test("F5: an unknown order is refused", async () => {
  const db = await seeded(); // no orders row
  begin(db, { env: ENV });
  const res = await post(handler, await verifyBody("order_missing", "pay_9"));
  assertEquals(res.status, 400);
  assertEquals(res.json.error, "unknown_order");
});
