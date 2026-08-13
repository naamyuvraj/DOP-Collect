// API tests for the `pay` edge function, driving the real handler.
//
// Focus: S7 (identity must come from the session, not a claimed agent id) and
// F5 (only a genuine duplicate may be reported as "already processed").

import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Db, newDb } from "./mock_supabase.ts";
import { BASE_ENV, begin, fetchCalls, load, post, sha256Hex } from "./harness.ts";

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

Deno.test("status without a token returns the PRICE LIST and nothing else", async () => {
  // The paywall has to render before anyone is signed in. Locking this down
  // completely made the screen come up blank with a dead Retry button.
  begin(await seeded(), { env: ENV });
  const res = await post(handler, { action: "status", agentId: THEIRS });

  assertEquals(res.status, 200);
  assertEquals(res.json.ok, true);
  assertEquals((res.json.plans as unknown[]).length, 2, "prices are public");

  // ...but nothing about any agent, least of all the one that was claimed.
  assertEquals(res.json.status, "unknown");
  assertEquals(res.json.planCode, "");
  assertEquals(res.json.periodEnd, null);
  assertEquals(res.json.daysLeft, 0);
});

Deno.test("S7: buying without a token is still refused", async () => {
  begin(await seeded(), { env: ENV });
  for (const action of ["order", "verify"]) {
    const res = await post(handler, { action, planCode: "m1", agentId: THEIRS });
    assertEquals(res.status, 401, `${action} must require a session`);
    assertEquals(res.json.error, "unauthorized");
  }
});

Deno.test("S7: an unauthenticated caller cannot create an order for anyone", async () => {
  const db = await seeded();
  begin(db, { env: ENV });
  await post(handler, { action: "order", planCode: "y1", agentId: THEIRS });
  assertEquals(db.tables.orders.length, 0);
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

Deno.test("S7: a revoked token buys nothing and reveals no entitlement", async () => {
  const db = await seeded();
  db.tables.device_sessions[0].revoked_at = new Date().toISOString();
  begin(db, { env: ENV });

  const status = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(status.json.status, "unknown", "treated as signed out");
  assertEquals(status.json.planCode, "");

  const order = await post(handler,
    { action: "order", planCode: "m1", token: MY_TOKEN });
  assertEquals(order.status, 401);
});

Deno.test("S7: a disabled account buys nothing and reveals no entitlement", async () => {
  const db = await seeded();
  db.tables.accounts[0].disabled = true;
  begin(db, { env: ENV });

  const status = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(status.json.status, "unknown");

  const order = await post(handler,
    { action: "order", planCode: "m1", token: MY_TOKEN });
  assertEquals(order.status, 401);
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
// P2 — you may only buy what the price list offers
// ---------------------------------------------------------------------------

Deno.test("P2: a RETIRED plan cannot be bought, even by code", async () => {
  const db = await seeded();
  // Pulled from sale in the dashboard — `status` stops listing it, so the only
  // way to name it is to have remembered the code.
  db.tables.plans.push({
    code: "legacy", name: "Old cheap tier", price_inr: 49, duration_days: 365,
    active: false, sort: 9,
  });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "order", planCode: "legacy", token: MY_TOKEN });

  assertEquals(res.status, 400);
  assertEquals(res.json.error, "bad_plan");
  assertEquals(db.tables.orders.length, 0);
  assertEquals(fetchCalls.length, 0, "Razorpay must never be asked for this order");
});

Deno.test("P2: a 0-day plan is refused — it would take money and grant nothing", async () => {
  const db = await seeded();
  db.tables.plans.push({
    code: "broken", name: "Misconfigured", price_inr: 199, duration_days: 0,
    active: true, sort: 9,
  });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "order", planCode: "broken", token: MY_TOKEN });
  assertEquals(res.status, 400);
  assertEquals(res.json.error, "bad_plan");
  assertEquals(fetchCalls.length, 0);
});

Deno.test("P2: the free trial still cannot be 'bought'", async () => {
  const db = await seeded();
  db.tables.plans.push({
    code: "trial", name: "Free trial", price_inr: 0, duration_days: 60,
    active: true, sort: 0,
  });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "order", planCode: "trial", token: MY_TOKEN });
  assertEquals(res.status, 400);
  assertEquals(res.json.error, "bad_plan");
});

// ---------------------------------------------------------------------------
// P1 — an order that wasn't recorded must never reach the checkout sheet
// ---------------------------------------------------------------------------

Deno.test("P1: an unrecorded order fails BEFORE the agent can pay for it", async () => {
  const db = await seeded();
  // The Razorpay order will be created fine; ours is the write that fails.
  db.failWrite = {
    table: "orders",
    error: { code: "42P01", message: 'relation "orders" does not exist' },
  };
  begin(db, {
    env: ENV,
    reply: () => ({ status: 200, json: { id: "order_LOST", amount: 19900, currency: "INR" } }),
  });

  const res = await post(handler, { action: "order", planCode: "m1", token: MY_TOKEN });

  // Handing back an orderId here opens the sheet, the agent pays, and then BOTH
  // activation paths bail on the missing order — money gone, nothing to trace.
  assertEquals(res.status, 500);
  assertEquals(res.json.ok, false);
  assertEquals(res.json.error, "not_recorded");
  assertEquals(res.json.orderId, undefined, "no order id may reach the client");
  assertEquals(db.tables.orders.length, 0);
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
  db.failWrite = {
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

// ---------------------------------------------------------------------------
// P9 — verify confirms your own order, not just any order
// ---------------------------------------------------------------------------

Deno.test("P9: a session cannot push ANOTHER agent's order through verify", async () => {
  const db = await withOrder();
  db.tables.orders.push({
    order_id: "order_theirs", agent_id: THEIRS, plan_code: "m1", amount: 19900,
  });
  begin(db, { env: ENV });

  const res = await post(handler, await verifyBody("order_theirs", "pay_2"));

  assertEquals(res.status, 400);
  assertEquals(res.json.error, "not_your_order");
  assertEquals(db.tables.payments.length, 0);
  // And nothing moved for either party.
  const theirs = db.tables.subscriptions.find((s) => s.agent_id === THEIRS)!;
  assertEquals(theirs.plan_code, "y1", "their yearly plan is untouched");
  assertEquals(db.tables.subscriptions.find((s) => s.agent_id === MINE), undefined);
});

// ---------------------------------------------------------------------------
// P3 — "a row exists for this ref" is not the same as "this payment settled"
// ---------------------------------------------------------------------------

Deno.test("P3: a payment that FAILED and was later captured still activates", async () => {
  const db = await withOrder();
  // Razorpay reuses the payment id on late authorisation: payment.failed landed
  // first and the webhook recorded it, then the same payment was captured.
  db.tables.payments.push({
    id: crypto.randomUUID(), agent_id: MINE, provider: "razorpay", ref: "pay_1",
    status: "failed", amount: 199, currency: "INR",
  });
  begin(db, { env: ENV });

  const res = await post(handler, await verifyBody());

  assertEquals(res.json.ok, true);
  assertEquals(res.json.note, undefined, "this is NOT a duplicate — it is the capture");
  const sub = db.tables.subscriptions.find((s) => s.agent_id === MINE);
  assert(sub, "the agent paid; access must exist");
  assertEquals(sub!.status, "active");
  assertEquals(sub!.plan_code, "m1");
  // The failed row was claimed, not duplicated — still one row per payment id.
  assertEquals(db.tables.payments.filter((p) => p.ref === "pay_1").length, 1);
  assertEquals(db.tables.payments[0].status, "success");
});

Deno.test("P3: claiming is once-only — a settled payment still can't extend twice", async () => {
  const db = await withOrder();
  db.tables.payments.push({
    id: crypto.randomUUID(), agent_id: MINE, provider: "razorpay", ref: "pay_1",
    status: "failed", amount: 199, currency: "INR",
  });
  begin(db, { env: ENV });

  const first = await post(handler, await verifyBody());
  const firstEnd = String(first.json.periodEnd);
  const again = await post(handler, await verifyBody());

  assertEquals(again.json.note, "already_processed", "the row is settled now");
  assertEquals(again.json.periodEnd, firstEnd, "period must not move on a replay");
});

Deno.test("P3: a claim that fails is an error, not a silent 'already processed'", async () => {
  const db = await withOrder();
  db.tables.payments.push({
    id: crypto.randomUUID(), agent_id: MINE, provider: "razorpay", ref: "pay_1",
    status: "failed", amount: 199, currency: "INR",
  });
  db.failWrite = {
    table: "payments", op: "update",
    error: { code: "42501", message: "permission denied" },
  };
  begin(db, { env: ENV });

  const res = await post(handler, await verifyBody());
  assertEquals(res.json.ok, false);
  assertEquals(res.json.error, "record_failed");
  assertEquals(db.tables.subscriptions.find((s) => s.agent_id === MINE), undefined);
});

Deno.test("P3: a recorded payment whose subscription didn't extend reports failure", async () => {
  const db = await withOrder();
  db.failWrite = {
    table: "subscriptions", op: "upsert",
    error: { code: "40001", message: "could not serialize access" },
  };
  begin(db, { env: ENV });

  const res = await post(handler, await verifyBody());

  // Money is on record and access is not. Saying "ok" here would leave the agent
  // staring at a paywall with a receipt in hand and nothing to show us.
  assertEquals(res.json.ok, false);
  assertEquals(res.json.error, "activate_failed");
  assertEquals(db.tables.subscriptions.find((s) => s.agent_id === MINE), undefined);
});

// ---------------------------------------------------------------------------
// Trial length + the day count
// ---------------------------------------------------------------------------

/** Whole days between now and an ISO instant, part-days rounded up. */
const daysTo = (iso: string) =>
  Math.ceil((new Date(iso).getTime() - Date.now()) / 86400_000);

Deno.test("the trial runs for the length the paywall advertises", async () => {
  // The live plans table advertises a 60-day free trial while app_config has no
  // trial_days at all, so the grant silently used the code's 14-day default.
  // Two different numbers for one promise.
  const db = await seeded();
  db.tables.plans.push({
    code: "trial", name: "Free trial", price_inr: 0, duration_days: 60,
    active: true, sort: 0,
  });
  db.tables.app_config.push({ key: "payments_enabled", value: true });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "status", token: MY_TOKEN });

  assertEquals(res.json.status, "trial");
  assertEquals(res.json.daysLeft, 60, "must match the advertised trial plan");
  const sub = db.tables.subscriptions.find((s) => s.agent_id === MINE)!;
  assertEquals(daysTo(String(sub.current_period_end)), 60);
});

Deno.test("app_config.trial_days is used only when there is no trial plan", async () => {
  const db = await seeded(); // seeded() has no `trial` plan row
  db.tables.app_config.push({ key: "trial_days", value: 21 });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(res.json.daysLeft, 21);
});

Deno.test("with neither, the trial falls back to 14 days", async () => {
  const db = await seeded();
  begin(db, { env: ENV });
  const res = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(res.json.daysLeft, 14);
});

Deno.test("daysLeft counts a part day as a whole day", async () => {
  const db = await seeded();
  db.tables.subscriptions.push({
    agent_id: MINE, plan_code: "m1", status: "active",
    current_period_end: new Date(Date.now() + 30 * 60_000).toISOString(),
  });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(res.json.status, "active", "30 minutes of access is access");
  assertEquals(res.json.daysLeft, 1, "never 0 while it still works");
});

Deno.test("an expired plan reports 0 days, never a negative", async () => {
  const db = await seeded();
  db.tables.subscriptions.push({
    agent_id: MINE, plan_code: "m1", status: "active",
    current_period_end: new Date(Date.now() - 5 * 86400_000).toISOString(),
  });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "status", token: MY_TOKEN });
  assertEquals(res.json.status, "expired");
  assertEquals(res.json.daysLeft, 0);
});

Deno.test("P11: an expired trial row is never re-granted a trial", async () => {
  // This is what admin/backfill_trials.sql writes for every agent that already
  // exists when payments are switched on: a trial row that ended at the flip.
  // If `resolve()` ever handed those agents a fresh trial, the backfill — and
  // with it the first month of revenue — would be silently undone.
  const db = await seeded();
  db.tables.plans.push({
    code: "trial", name: "Free trial", price_inr: 0, duration_days: 60,
    active: true, sort: 0,
  });
  db.tables.subscriptions.push({
    agent_id: MINE, plan_code: "trial", status: "expired",
    current_period_end: new Date(Date.now() - 1000).toISOString(),
    trial_used: true,
  });
  begin(db, { env: ENV });

  const res = await post(handler, { action: "status", token: MY_TOKEN });

  assertEquals(res.json.status, "expired", "straight to the paywall");
  assertEquals(res.json.daysLeft, 0);
  assertEquals(
    db.tables.subscriptions.filter((s) => s.agent_id === MINE).length, 1,
    "no second row, no second trial",
  );
});

Deno.test("renewing early adds to the remaining time, it does not reset it", async () => {
  const db = await withOrder();
  db.tables.subscriptions.push({
    agent_id: MINE, plan_code: "m1", status: "active",
    current_period_end: new Date(Date.now() + 10 * 86400_000).toISOString(),
  });
  begin(db, { env: ENV });

  await post(handler, await verifyBody()); // m1 = 30 more days

  const sub = db.tables.subscriptions.find((s) => s.agent_id === MINE)!;
  assertEquals(daysTo(String(sub.current_period_end)), 40,
    "10 remaining + 30 bought; renewing early must not burn the 10");
});

Deno.test("renewing after expiry starts from today, not from the old end", async () => {
  const db = await withOrder();
  db.tables.subscriptions.push({
    agent_id: MINE, plan_code: "m1", status: "expired",
    current_period_end: new Date(Date.now() - 100 * 86400_000).toISOString(),
  });
  begin(db, { env: ENV });

  await post(handler, await verifyBody());

  const sub = db.tables.subscriptions.find((s) => s.agent_id === MINE)!;
  assertEquals(daysTo(String(sub.current_period_end)), 30,
    "a lapsed agent gets a full period, not one backdated into the past");
});

Deno.test("F5: an unknown order is refused", async () => {
  const db = await seeded(); // no orders row
  begin(db, { env: ENV });
  const res = await post(handler, await verifyBody("order_missing", "pay_9"));
  assertEquals(res.status, 400);
  assertEquals(res.json.error, "unknown_order");
});
