// API tests for the `razorpay-webhook` edge function, driving the real handler.
//
// This is the path that runs when nothing else can: the agent paid and the app
// died before it could verify. Until now it was the only money code in the repo
// with no tests at all — so the cases here are the ones where being wrong costs
// a real payment:
//   - a forged or unsigned event must change nothing,
//   - a captured payment must activate exactly once, whoever gets there first,
//   - a payment that FAILED and was later captured must still activate (P3),
//   - a transient write failure must ask Razorpay to try again (P4), and a
//     payment we recorded but could not activate must be loud, not silent.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Db, newDb } from "./mock_supabase.ts";
import { BASE_ENV, begin, load, postRaw } from "./harness.ts";

const ENV = { ...BASE_ENV, RAZORPAY_WEBHOOK_SECRET: "whsec_test" };
const AGENT = "AGENT-MINE-01";

const handler = await load("razorpay-webhook");

function seeded(): Db {
  const db = newDb();
  db.tables.plans.push({
    code: "m1", name: "Monthly", price_inr: 199, duration_days: 30,
    active: true, sort: 1,
  });
  db.tables.orders.push({
    order_id: "order_1", agent_id: AGENT, plan_code: "m1", amount: 19900,
  });
  return db;
}

/** Razorpay signs the RAW body: X-Razorpay-Signature = HMAC_SHA256(body, secret). */
async function sign(raw: string, secret = ENV.RAZORPAY_WEBHOOK_SECRET) {
  const k = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const s = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(raw));
  return [...new Uint8Array(s)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const captured = (orderId = "order_1", paymentId = "pay_1", amount = 19900) => ({
  event: "payment.captured",
  payload: { payment: { entity: { id: paymentId, order_id: orderId, amount } } },
});

const failed = (orderId = "order_1", paymentId = "pay_1") => ({
  event: "payment.failed",
  payload: {
    payment: {
      entity: {
        id: paymentId, order_id: orderId, amount: 19900,
        notes: { agent_id: AGENT, plan: "m1" },
      },
    },
  },
});

/** Deliver an event the way Razorpay would, correctly signed. */
async function deliver(db: Db, event: unknown) {
  begin(db, { env: ENV });
  const raw = JSON.stringify(event);
  return await postRaw(handler, raw, { "x-razorpay-signature": await sign(raw) });
}

const subOf = (db: Db) => db.tables.subscriptions.find((s) => s.agent_id === AGENT);
const daysTo = (iso: string) =>
  Math.ceil((new Date(iso).getTime() - Date.now()) / 86400_000);

// ---------------------------------------------------------------------------
// Signature — the only thing standing between this endpoint and free access
// ---------------------------------------------------------------------------

Deno.test("an unsigned event changes nothing", async () => {
  const db = seeded();
  begin(db, { env: ENV });
  const res = await postRaw(handler, JSON.stringify(captured()));
  assertEquals(res.status, 400);
  assertEquals(db.tables.payments.length, 0);
  assertEquals(subOf(db), undefined);
});

Deno.test("a forged signature changes nothing", async () => {
  const db = seeded();
  begin(db, { env: ENV });
  const raw = JSON.stringify(captured());
  const res = await postRaw(handler, raw, {
    "x-razorpay-signature": await sign(raw, "not-the-secret"),
  });
  assertEquals(res.status, 400);
  assertEquals(db.tables.payments.length, 0);
  assertEquals(subOf(db), undefined);
});

Deno.test("a signature over DIFFERENT bytes is refused", async () => {
  const db = seeded();
  begin(db, { env: ENV });
  // Signed a ₹199 order, delivered a body claiming a different payment.
  const signedFor = JSON.stringify(captured("order_1", "pay_1"));
  const delivered = JSON.stringify(captured("order_1", "pay_EVIL"));
  const res = await postRaw(handler, delivered, {
    "x-razorpay-signature": await sign(signedFor),
  });
  assertEquals(res.status, 400);
  assertEquals(db.tables.payments.length, 0);
});

Deno.test("with no secret configured, nothing is accepted", async () => {
  const db = seeded();
  begin(db, { env: { ...BASE_ENV, RAZORPAY_WEBHOOK_SECRET: "" } });
  const raw = JSON.stringify(captured());
  // No secret means nothing can be verified, so no signature can be right —
  // including one an attacker computed with a key of their choosing.
  const res = await postRaw(handler, raw, {
    "x-razorpay-signature": await sign(raw, "attacker-picked-secret"),
  });
  assertEquals(res.status, 400, "fail closed rather than activate on an empty secret");
  assertEquals(db.tables.payments.length, 0);
});

// ---------------------------------------------------------------------------
// Activation — the reason this endpoint exists
// ---------------------------------------------------------------------------

Deno.test("a captured payment activates the subscription", async () => {
  const db = seeded();
  const res = await deliver(db, captured());

  assertEquals(res.status, 200);
  assertEquals(res.json.outcome, "ok");
  const sub = subOf(db)!;
  assertEquals(sub.status, "active");
  assertEquals(sub.plan_code, "m1");
  assertEquals(daysTo(String(sub.current_period_end)), 30);
  assertEquals(db.tables.payments.length, 1);
  assertEquals(db.tables.payments[0].status, "success");
  assertEquals(db.tables.payments[0].agent_id, AGENT, "credited to the ORDER's agent");
});

Deno.test("`order.paid` activates the same way", async () => {
  const db = seeded();
  const res = await deliver(db, { ...captured(), event: "order.paid" });
  assertEquals(res.json.outcome, "ok");
  assertEquals(subOf(db)!.status, "active");
});

Deno.test("the plan and agent come from the ORDER, never the event", async () => {
  const db = seeded();
  // A signed event can still carry lies; only the recorded order decides.
  await deliver(db, {
    event: "payment.captured",
    payload: {
      payment: {
        entity: {
          id: "pay_1", order_id: "order_1", amount: 1,
          notes: { agent_id: "AGENT-SOMEONE-ELSE", plan: "y1" },
        },
      },
    },
  });
  const sub = subOf(db)!;
  assertEquals(sub.plan_code, "m1", "not the plan the event claimed");
  assertEquals(db.tables.payments[0].agent_id, AGENT);
  assertEquals(
    db.tables.subscriptions.find((s) => s.agent_id === "AGENT-SOMEONE-ELSE"),
    undefined,
  );
});

Deno.test("a redelivered event does NOT extend twice", async () => {
  const db = seeded();
  await deliver(db, captured());
  const firstEnd = String(subOf(db)!.current_period_end);

  const again = await deliver(db, captured());

  assertEquals(again.status, 200);
  assertEquals(again.json.outcome, "settled");
  assertEquals(subOf(db)!.current_period_end, firstEnd, "period must not move");
  assertEquals(db.tables.payments.length, 1);
});

Deno.test("renewal stacks onto the time already paid for", async () => {
  const db = seeded();
  db.tables.subscriptions.push({
    agent_id: AGENT, plan_code: "m1", status: "active",
    current_period_end: new Date(Date.now() + 10 * 86400_000).toISOString(),
  });
  await deliver(db, captured());
  assertEquals(daysTo(String(subOf(db)!.current_period_end)), 40, "10 left + 30 bought");
});

Deno.test("an event for an order we never recorded is acked, not activated", async () => {
  const db = seeded();
  const res = await deliver(db, captured("order_UNKNOWN", "pay_9"));
  assertEquals(res.status, 200, "a retry cannot conjure the order row");
  assertEquals(res.json.outcome, "ignored");
  assertEquals(db.tables.payments.length, 0);
  assertEquals(subOf(db), undefined);
});

// ---------------------------------------------------------------------------
// P3 — a `failed` row must not swallow a later capture of the same payment id
// ---------------------------------------------------------------------------

Deno.test("P3: failed, then captured on the same payment id, still activates", async () => {
  const db = seeded();

  const first = await deliver(db, failed());
  assertEquals(first.status, 200);
  assertEquals(db.tables.payments.length, 1);
  assertEquals(db.tables.payments[0].status, "failed");

  // Razorpay reuses the payment id on late authorisation.
  const second = await deliver(db, captured());

  assertEquals(second.json.outcome, "ok", "this is the capture, not a duplicate");
  const sub = subOf(db);
  assert(sub, "the agent paid; access must exist");
  assertEquals(sub!.status, "active");
  assertEquals(daysTo(String(sub!.current_period_end)), 30);
  // Claimed in place — still one row per payment id.
  assertEquals(db.tables.payments.length, 1);
  assertEquals(db.tables.payments[0].status, "success");
});

Deno.test("P3: a failed payment on its own grants nothing", async () => {
  const db = seeded();
  const res = await deliver(db, failed());
  assertEquals(res.status, 200);
  assertEquals(subOf(db), undefined, "a failure must never touch entitlement");
});

// ---------------------------------------------------------------------------
// P6 — `payments.amount` is rupees, in every row, from every path
// ---------------------------------------------------------------------------

Deno.test("P6: a captured payment is recorded in RUPEES, from the order", async () => {
  const db = seeded(); // orders.amount is 19900 paise
  await deliver(db, captured());
  assertEquals(db.tables.payments[0].amount, 199, "rupees, not paise");
});

Deno.test("P6: a FAILED payment is recorded in rupees too", async () => {
  const db = seeded();
  await deliver(db, failed()); // the event carries 19900 paise
  // Written raw, this showed as ₹19,900 next to the ₹199 successes.
  assertEquals(db.tables.payments[0].amount, 199);
});

Deno.test("P6: the amount comes from the order, not a since-edited plan", async () => {
  const db = seeded();
  // Price raised in the dashboard after this agent checked out at ₹199.
  db.tables.plans[0].price_inr = 299;
  await deliver(db, captured());
  assertEquals(db.tables.payments[0].amount, 199, "bill what was actually charged");
});

// ---------------------------------------------------------------------------
// P4 — transient failures ask for a retry; a stranded payment is loud
// ---------------------------------------------------------------------------

Deno.test("P4: a transient write failure asks Razorpay to send it again", async () => {
  const db = seeded();
  db.failWrite = {
    table: "payments", op: "insert",
    error: { code: "40001", message: "could not serialize access" },
  };
  const res = await deliver(db, captured());

  assertEquals(res.status, 500, "200 would burn the one free recovery we get");
  assertEquals(res.json.outcome, "retry");
  assertEquals(subOf(db), undefined);
});

Deno.test("P4: and the retry then activates cleanly", async () => {
  const db = seeded();
  db.failWrite = {
    table: "payments", op: "insert",
    error: { code: "40001", message: "could not serialize access" },
  };
  await deliver(db, captured());          // fails, asks for a retry
  const retry = await deliver(db, captured()); // Razorpay redelivers

  assertEquals(retry.status, 200);
  assertEquals(retry.json.outcome, "ok");
  assertEquals(subOf(db)!.status, "active");
  assertEquals(db.tables.payments.length, 1, "no duplicate row from the retry");
});

Deno.test("P4: a payment recorded but NOT activated is reported, not swallowed", async () => {
  const db = seeded();
  db.failWrite = {
    table: "subscriptions", op: "upsert",
    error: { code: "42501", message: "permission denied" },
  };
  const res = await deliver(db, captured());

  assertEquals(res.status, 500, "this one needs a human — it must not look fine");
  assertEquals(res.json.outcome, "stranded");
  assertEquals(db.tables.payments.length, 1, "the money IS on record");
  assertEquals(subOf(db), undefined, "but the access is not");
});

Deno.test("P4: the retry after a stranded payment is safe (it just no-ops)", async () => {
  const db = seeded();
  db.failWrite = {
    table: "subscriptions", op: "upsert",
    error: { code: "42501", message: "permission denied" },
  };
  await deliver(db, captured());
  const retry = await deliver(db, captured());

  // It cannot self-heal (the payment row is already `success`), but it must not
  // make things worse either — no second payment row, no double extension.
  assertEquals(retry.status, 200);
  assertEquals(retry.json.outcome, "settled");
  assertEquals(db.tables.payments.length, 1);
});

// ---------------------------------------------------------------------------
// Refunds + malformed input
// ---------------------------------------------------------------------------

Deno.test("a refund marks the payment, and deliberately leaves access alone", async () => {
  const db = seeded();
  await deliver(db, captured());
  const end = String(subOf(db)!.current_period_end);

  const res = await deliver(db, {
    event: "refund.created",
    payload: { refund: { entity: { id: "rfnd_1", payment_id: "pay_1" } } },
  });

  assertEquals(res.status, 200);
  assertEquals(db.tables.payments[0].status, "refunded");
  // Partial refunds are common; revoking access is a business decision.
  assertEquals(subOf(db)!.current_period_end, end);
});

Deno.test("a capture redelivered AFTER a refund does not hand the time back", async () => {
  const db = seeded();
  await deliver(db, captured());
  const end = String(subOf(db)!.current_period_end);
  await deliver(db, {
    event: "refund.processed",
    payload: { refund: { entity: { id: "rfnd_1", payment_id: "pay_1" } } },
  });

  // Razorpay redelivers the original capture (it can, if an earlier delivery
  // 500'd). `refunded` is a settled state, so there is nothing left to claim.
  const late = await deliver(db, captured());

  assertEquals(late.json.outcome, "settled");
  assertEquals(db.tables.payments[0].status, "refunded", "still refunded");
  assertEquals(subOf(db)!.current_period_end, end, "no free time");
});

Deno.test("a malformed body is acked, not retried forever", async () => {
  const db = seeded();
  begin(db, { env: ENV });
  const raw = "{not json";
  const res = await postRaw(handler, raw, { "x-razorpay-signature": await sign(raw) });
  assertEquals(res.status, 200);
  assertEquals(db.tables.payments.length, 0);
});

Deno.test("a captured event missing its ids does nothing", async () => {
  const db = seeded();
  const res = await deliver(db, {
    event: "payment.captured",
    payload: { payment: { entity: { id: null, order_id: null } } },
  });
  assertEquals(res.status, 200);
  assertEquals(db.tables.payments.length, 0);
  assertEquals(subOf(db), undefined);
});

Deno.test("GET is refused", async () => {
  begin(seeded(), { env: ENV });
  const res = await handler(new Request("https://fn.test/", { method: "GET" }));
  assertEquals(res.status, 405);
});
