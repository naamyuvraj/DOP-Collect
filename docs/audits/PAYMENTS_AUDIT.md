# DOP Collect — Payments Audit (logic · security · fallbacks)

**Date:** 13 August 2026 · companion to [SECURITY_AUDIT.md](SECURITY_AUDIT.md) (11 Aug), which covers the app/backend at large.
**Scope:** [pay/index.ts](supabase/functions/pay/index.ts), [razorpay-webhook/index.ts](supabase/functions/razorpay-webhook/index.ts), [subscription.dart](lib/services/subscription.dart), [razorpay_checkout.dart](lib/services/razorpay_checkout.dart), [paywall_screen.dart](lib/screens/paywall_screen.dart), the root gate in [main.dart](lib/main.dart#L223), [schema_payments.sql](admin/schema_payments.sql), and the dashboard's plans/payments pages.
**Baseline at review time:** `deno test` 31/31 · `flutter test` 316/316.
**After the fix pass (13 Aug):** `deno test` **71/71** · `flutter test` 316/316 · `flutter analyze` clean · `deno check` clean on all five functions · dashboard `tsc` + `next build` clean.

**Threat model for money specifically:** (a) a paying agent whose activation silently fails and who has no way to recover it, (b) an agent on a rooted phone trying to keep access after expiry, (c) an agent trying to read or buy against someone else's agent id, (d) replay/race between the app's `verify` and Razorpay's webhook, (e) operator error — a flag flipped, a plan retired, a secret unset.

---

## Findings at a glance

| ID | Sev | Finding | Class | Status |
|---|---|---|---|---|
| **P1** | 🟠 HIGH | `orders` insert failure is unchecked → customer pays, **no activation path can recover it** | fallback | ✅ fixed |
| **P2** | 🟡 MED | `plans.active` is not enforced at purchase — a retired tier is still buyable at its old price | logic | ✅ fixed |
| **P3** | 🟡 MED | A `payment.failed` row **poisons a later capture of the same payment id** → paid, never activated | logic | ✅ fixed |
| **P4** | 🟡 MED | Failed activation has **no repair path**: no retry, no manual grant, no reconciliation | fallback | ✅ retry + manual grant; reconciliation open |
| **P5** | 🟡 MED | Paywall is **client-side only** — no server-side entitlement check on the paid capabilities | security | ✅ fixed (`groq`) |
| **P6** | 🔵 LOW | `payments.amount` mixes **rupees and paise** → failed payments display 100× | data | ✅ fixed |
| **P7** | 🔵 LOW | Checkout result's `orderId` may be empty → false "payment didn't go through" on a real payment | fallback | ✅ fixed |
| **P8** | 🔵 LOW | Rate limits **fail open** if `bump_rate` errors | security | ✅ fail-open kept, now logged |
| **P9** | 🔵 INFO | `verify` accepts any valid session, not the order's owner (not exploitable — activation is order-keyed) | security | ✅ fixed |
| **P10** | 🔵 INFO | The **webhook has zero tests** — the least-verified money code in the repo | coverage | ✅ 24 tests added |
| **P11** | 🔵 INFO | Trial **regrants in full** for every existing agent the day `payments_enabled` flips on | product | ✅ backfill script (run before the flip) |
| **P12** | 🔵 INFO | Refunds don't revoke access, and the documented remedy (dashboard) **doesn't exist** | ops | ✅ control built |

## Fix pass — 13 August 2026

Everything above except P11 and the reconciliation half of P4 is implemented and
tested. Test count went 31 → 70 on the edge functions.

| Change | Where |
|---|---|
| The `orders` insert is checked and **fails before the charge** (`not_recorded`, 500) — a stranded Razorpay order just expires unpaid | [pay/index.ts](supabase/functions/pay/index.ts) |
| `order` now resolves the plan from the **same active-only list `status` serves**, and refuses a 0-day plan — so `plans.active` is a real kill switch | [pay/index.ts](supabase/functions/pay/index.ts) |
| A 23505 on the payment ref no longer means "done": the row is **claimed** unless it is already settled (`success` or `refunded`), so a failed→captured payment activates, the verify/webhook race still extends exactly once, and a capture redelivered after a refund can't hand the time back | [pay/index.ts](supabase/functions/pay/index.ts), [razorpay-webhook/index.ts](supabase/functions/razorpay-webhook/index.ts) |
| The `subscriptions` upsert error is checked in both paths — "paid and nothing happened" can no longer be reported as `ok` | both |
| The webhook returns a typed outcome and **500s on a transient failure** (Razorpay retries; duplicates are safe) or a stranded payment (an alarm) | [razorpay-webhook/index.ts](supabase/functions/razorpay-webhook/index.ts) |
| **Manual repair**: `PATCH /api/subscriptions` (grant days / end access), wired into Plans → Subscribers, with every adjustment logged as a `manual` payments row that revenue excludes | [api/subscriptions/route.ts](dashboard/app/api/subscriptions/route.ts), [plans/page.tsx](dashboard/app/\(dash\)/plans/page.tsx) |
| **Server-side entitlement** in the `groq` proxy — refuses only an agent it can positively identify as expired; inert until `payments_enabled` | [groq/index.ts](supabase/functions/groq/index.ts), [groq_client.dart](lib/assistant/groq_client.dart) |
| `payments.amount` is rupees everywhere, taken from `orders.amount` (what was actually charged, not a since-edited plan price) | both functions |
| The checkout falls back to the **server-issued** order id, so a callback without one no longer fails a real payment | [razorpay_checkout.dart](lib/services/razorpay_checkout.dart) |
| `verify` requires the session to **own** the order | [pay/index.ts](supabase/functions/pay/index.ts) |
| `bump_rate` failures are logged — still fail-open, no longer invisible | [pay/index.ts](supabase/functions/pay/index.ts) |
| **No free trial for existing agents** at launch: a one-shot backfill writes an already-expired row per current agent, so only genuinely new agents get a trial. Must run *before* the flip — after it, agents have already created their own trial rows | [admin/backfill_trials.sql](admin/backfill_trials.sql) |
| Ops: a **"Switching payments on"** runbook with the ordering constraints (`otp_required` and the backfill both before `payments_enabled`), webhook-secret verification, and a "they paid and have no access" procedure | [RUNBOOK.md](RUNBOOK.md) |

Test coverage added: 24 webhook tests (signature forgery, activation, the
failed→captured case, retry/stranded outcomes, refunds, malformed input), 7
`groq` entitlement tests, and 8 in `pay` for P1/P2/P3/P9.

**No CRITICALs.** The core money logic is sound: identity is session-derived, the plan comes from the server-recorded order, signatures are HMAC-SHA256 timing-safe on both paths, and the unique payment `ref` makes activation idempotent. The weaknesses are concentrated in what happens when something *fails* mid-flow.

---

# 🟠 HIGH

## P1. The `orders` insert error is never checked — a lost order row is unrecoverable money

**Where:** [pay/index.ts:270](supabase/functions/pay/index.ts#L270)

```ts
const order = await rzp.json();          // Razorpay order now EXISTS
...
await sb.from("orders").insert({ ... }); // error discarded
return json({ ok: true, orderId: order.id, ... });
```

The Razorpay order is created first, then recorded locally — and the local insert's error is dropped. If that row doesn't persist (transient DB error, an RLS change, schema drift, `schema_payments.sql` not run on a fresh project), the function still hands the client a live order id, the checkout sheet opens, and **the customer pays.**

Then both activation paths look the order up and bail:

- `verify` → `activate()` → `if (!ord) return { ok: false, error: "unknown_order" }` → app shows "Verify failed".
- webhook → `activate()` → `if (!ord) return;` → **silent**, and Razorpay is told 200.

Money is captured, no entitlement is granted, and nothing in `payments` links the charge to an agent — so even a manual investigation starts from the Razorpay dashboard, not from ours. Compounded by P4 (no way to grant access by hand).

**Fix:** check the insert and abort **before** returning the order to the client. Nothing has been charged at that point, so failing here is free:

```ts
const rec = await sb.from("orders").insert({ order_id: order.id, agent_id: agentId, plan_code: plan.code, amount: order.amount });
if (rec.error) {
  console.error("order not recorded", order.id, rec.error);
  return json({ ok: false, error: "not_recorded" }, 500);   // no checkout, no charge
}
```

The stranded Razorpay order simply expires unpaid. Worth a test alongside the existing `F5: a NON-duplicate insert failure…` case, which already establishes exactly this principle one step later in the flow.

---

# 🟡 MEDIUM

## P2. `plans.active` isn't enforced at purchase — and `duration_days` isn't validated

**Where:** [pay/index.ts:243-246](supabase/functions/pay/index.ts#L243)

```ts
const { data: plan } = await sb.from("plans").select("*").eq("code", String(body.planCode)).maybeSingle();
if (!plan || Number(plan.price_inr) <= 0) return json({ ok: false, error: "bad_plan" }, 400);
```

`status` lists only `active` plans, but `order` resolves any code. The dashboard describes `plans.active` as a per-plan kill switch — *"hide/show a tier to all users instantly"* ([api/plans/route.ts](dashboard/app/api/plans/route.ts#L38)) — which is not what it does. An install that cached an old plan list, or anyone reading a code off a rooted device, can still buy a retired tier at whatever price and duration that row still carries. Retiring a mispriced plan therefore doesn't actually stop sales of it.

Nothing validates `duration_days > 0` either: a plan saved with 0 days (easy to do from the plans editor) takes the money and extends access by nothing.

**Fix:** `.eq("code", …).eq("active", true)` and `Number(plan.duration_days) > 0` in the same guard. Cheap, and it makes the dashboard's advertised control real.

## P3. A `payment.failed` row silently blocks a later capture of the same payment id

**Where:** [pay/index.ts:215-221](supabase/functions/pay/index.ts#L215), [razorpay-webhook/index.ts:81-91](supabase/functions/razorpay-webhook/index.ts#L81), [schema_payments.sql:59](admin/schema_payments.sql#L59)

The idempotency key is `unique (ref) where provider = 'razorpay'` — **status-agnostic**. Both `activate()`s treat any `23505` as *"the other path already handled this, don't extend."* But the webhook's `payment.failed` branch inserts a row for the same `ref` with `status: 'failed'`:

```ts
await sb.from("payments").insert({ ..., ref: String(p.id), status: "failed" });
```

Razorpay reuses the payment id across late authorization and delayed capture — a payment reported failed can subsequently be authorized and captured under the **same id**. When that `payment.captured` arrives, the insert collides with the failed row, is read as "already processed", and the subscription is **never extended**. The webhook returns silently; the app's `verify` returns `ok: true, note: "already_processed"` with the *old* `periodEnd`. So the customer is told the payment already went through, while their expiry never moved. That is precisely the outcome the comment on line 213 says this flow must never produce.

**Fix:** on `23505`, don't assume success — claim the row conditionally, and let the update's result decide who extends:

```ts
if (pay.error?.code === "23505") {
  const claim = await sb.from("payments")
    .update({ status: "success", agent_id: ord.agent_id, plan_code: plan.code, order_id: orderId })
    .eq("provider", "razorpay").eq("ref", paymentId).neq("status", "success")
    .select("id");
  if (!claim.data?.length) return { ok: true, already: true, periodEnd: await endOf() }; // genuine duplicate
  // we won the claim — fall through and extend
}
```

`.neq("status","success")` keeps the verify-vs-webhook race safe: exactly one caller can flip a non-success row, so the subscription is still extended once.

## P4. A failed activation has no retry, no manual grant, and no reconciliation

**Where:** [pay/index.ts:215](supabase/functions/pay/index.ts#L215), [razorpay-webhook/index.ts:81](supabase/functions/razorpay-webhook/index.ts#L81), dashboard

Both paths handle a non-duplicate insert failure *honestly* — they refuse to report success — which is the right call and is tested. But the end state is a paid customer with no access and a `console.error` in the edge-function log that nobody is watching. Three gaps:

1. **The webhook returns 200 on a DB failure** ([line 149](supabase/functions/razorpay-webhook/index.ts#L149)), with the note *"retries wouldn't help"*. For a transient DB error a retry is exactly what would help — Razorpay retries a non-2xx on a backoff schedule for ~24h, which is a free, correct recovery mechanism being declined. Duplicates are already safe (unique `ref`), so retries cost nothing. Return **500 only on the non-duplicate insert failure**; keep 200 for parse errors, unknown orders, and handled events.
2. **No manual repair.** The dashboard is read-only for `subscriptions` — [plans/page.tsx](dashboard/app/\(dash\)/plans/page.tsx) and [payments/page.tsx](dashboard/app/\(dash\)/payments/page.tsx) only display, and [api/plans/route.ts](dashboard/app/api/plans/route.ts) writes `plans` and `app_config`, never `subscriptions`. When P1 or P3 strands a customer, support has no button to press.
3. **No reconciliation.** Nothing ever compares Razorpay's captured payments against our `payments` table, so a stranded charge is found only when the customer complains — and the refund policy in the paywall promises a 7-day window ([paywall_screen.dart:380](lib/screens/paywall_screen.dart#L380)).

**Also ops:** the webhook fails closed if `RAZORPAY_WEBHOOK_SECRET` is unset — it rejects **every** event with a 400 and no alert. The entire "app was killed right after paying" safety net would be silently dead. Verify the secret is set on both Supabase and the Razorpay dashboard, and confirm one real event lands before flipping `payments_enabled` on.

**Recommend:** (a) 500-on-transient in the webhook, (b) an admin "grant N days / set expiry" action on the subscriptions view, (c) a daily reconcile job over Razorpay's payments API vs `payments` that flags captured-but-not-recorded.

## P5. The paywall is enforced only on the client; the paid server capability is ungated

**Where:** [main.dart:223](lib/main.dart#L223), [subscription.dart:106](lib/services/subscription.dart#L106), [groq/index.ts](supabase/functions/groq/index.ts), [ingest/index.ts](supabase/functions/ingest/index.ts)

`Subscription.blocked` is the one and only gate, and it is deliberately fail-open:

```dart
static bool get blocked => RemoteConfig.paymentsEnabled && (_current?.expired ?? false);
```

The gate's *placement* is right — one root-level gate rather than per-screen checks that new screens forget. But its inputs are all client-side: status is cached in `SharedPreferences` (not the Keystore), and `expired` is only ever reached by a server round-trip. So **clear app data, or keep the phone off the network, and access returns indefinitely.** Meanwhile the assistant proxy (`groq`) and `ingest` — the parts that actually cost money to serve — never look at `subscriptions`; `groq` doesn't even receive a session token, only a device id and the optional integrity header.

The fail-open behaviour on the **UI** gate should stay: locking a paying agent out mid-collection-round on flaky village data is a far worse failure than a few free days. The fix is to enforce where it can't be bypassed — thread the session token into `groq` the way `pay` does, resolve the agent from `device_sessions`, and refuse when `current_period_end < now()` **and** `payments_enabled` is on. That turns the subscription from a client-side suggestion into an actual entitlement, without touching the offline-tolerant UX.

---

# 🔵 LOW / INFO

## P6. `payments.amount` mixes rupees and paise

Success rows write `amount: plan.price_inr` — **rupees** (199). The webhook's `payment.failed` branch writes Razorpay's `p.amount` — **paise** (19900) ([razorpay-webhook/index.ts:129](supabase/functions/razorpay-webhook/index.ts#L129)). The payments page renders every row through `inr(p.amount)` ([payments/page.tsx:109](dashboard/app/\(dash\)/payments/page.tsx#L109)), so a failed ₹199 attempt displays as **₹19,900**. `v_mrr` filters `status = 'success'`, so revenue totals are correct — only the table lies. Separately, `orders.amount` is paise while `payments.amount` is rupees for the same transaction.

Pick one unit (paise, divided at display, matching Razorpay) — and prefer recording the authoritative `ord.amount` over re-reading `plan.price_inr`, which can have been edited between order and capture.

## P7. The checkout callback's `orderId` can be empty → a false failure on a real payment

**Where:** [razorpay_checkout.dart:24](lib/services/razorpay_checkout.dart#L24)

```dart
_finish(RazorpayResult(r.orderId ?? '', r.paymentId ?? '', r.signature ?? ''));
```

If Razorpay's success callback omits `orderId`, `verify` signs `|pay_x`, the HMAC won't match, and the user gets the "Payment didn't go through" dialog on a payment that succeeded. The webhook rescues the entitlement a moment later, but the immediate experience is a false failure on a charged card. The order id is already known and server-issued — use `order.orderId` from the `RazorpayOrder` rather than the callback's copy.

## P8. Rate limits fail open

[pay/index.ts:110-111](supabase/functions/pay/index.ts#L110) — `((await sb.rpc("bump_rate", …)).data as number) ?? 0`. If the RPC errors, every threshold compares against 0 and passes. Same posture as `groq`/`ingest`, so this is consistent rather than novel, but a failing `bump_rate` removes the abuse control with no signal. (Note the per-device key comes from the client-controlled `x-device-id`; the per-IP window is the real backstop.)

## P9. `verify` authenticates *a* session, not the order's owner

`activate()` credits `ord.agent_id`, so a stranger pushing someone else's order through gains nothing — and they'd need a genuine Razorpay signature, meaning the payment really happened. Not exploitable, but the session check on `verify` is currently decorative. One line makes it mean something: `if (ord.agent_id !== agentId) return json({ ok:false, error:"unauthorized" }, 403)`.

## P10. The webhook has no tests

`supabase/tests/` covers `otp` and `pay` well (31 passing, including the S7 identity cases and the F5 duplicate-vs-error distinction) but nothing exercises `razorpay-webhook` — the path that exists *specifically* for when the app dies after payment, i.e. the one that runs when nothing else can. Its own header records that the file failed `deno check` with 13 errors and was never typechecked until recently. Worth mirroring the F5 tests against it: signature rejection, unknown order, duplicate-ref no-op, and (after P3) failed-then-captured.

## P11. The trial regrants in full when the switch flips

While `payments_enabled` is false, `resolve()` returns an ephemeral trial and persists no row ([pay/index.ts:167](supabase/functions/pay/index.ts#L167)) — so `daysLeft` silently resets on every status call. The day payments are switched on, **every** existing agent, including year-old users, gets a fresh full trial (currently the `trial` plan's `duration_days`). `subscriptions.trial_used` exists in the schema and is never read. The comment says this is deliberate (avoiding trial-row spam), and the trade is real — but it delays first revenue by a whole trial length. If that isn't intended, backfill `subscriptions` rows at flip time with a shorter or already-consumed trial.

## P12. Refunds don't revoke access, and the stated remedy doesn't exist

`refund.created` / `refund.processed` mark the payment refunded and deliberately leave access alone, pointing at the dashboard: *"do it from the dashboard by shortening the subscription"* ([razorpay-webhook/index.ts:137](supabase/functions/razorpay-webhook/index.ts#L137)). There is no such control — see P4(2). Either build the subscription-edit action or amend the comment so the next person doesn't go looking for it.

---

## What's already right

Worth recording, because most of it is the hard part:

| Control | Where |
|---|---|
| Identity is **session-derived only** — a client-supplied `agentId` is ignored for status, order and verify (tested: S7) | [pay/index.ts:77-98](supabase/functions/pay/index.ts#L77) |
| Plan + agent read from the **server-recorded order**, never the client — the signature doesn't bind the plan, so this is what stops paying cheap and claiming expensive | [pay/index.ts:193](supabase/functions/pay/index.ts#L193) |
| **HMAC-SHA256, timing-safe** on both the app verify (`orderId\|paymentId`) and the webhook (raw body); the webhook **fails closed** with no secret | both functions |
| **Idempotent** activation via `unique(ref)` — replay and the verify/webhook race both no-op (tested: F5) | [schema_payments.sql:59](admin/schema_payments.sql#L59) |
| Renewal **stacks** from `max(now, current_period_end)` — early renewal doesn't burn remaining days (tested both directions) | [pay/index.ts:223](supabase/functions/pay/index.ts#L223) |
| `key_secret` never ships in the app; the checkout is a **seam** so patch builds degrade to "Soon" instead of crashing | [subscription.dart:81](lib/services/subscription.dart#L81) |
| A non-duplicate insert failure is **reported as failure**, not papered over as success (tested) | [pay/index.ts:215](supabase/functions/pay/index.ts#L215) |
| **One** root-level gate, not per-screen checks; fail-open on unknown/offline; `daysLeft` ages against `periodEnd` instead of replaying a stale count | [main.dart:223](lib/main.dart#L223), [subscription.dart:51](lib/services/subscription.dart#L51) |
| Entitlement **cleared on logout** so the next agent on the same phone can't inherit it (tested) | [subscription.dart:175](lib/services/subscription.dart#L175) |
| **"I've already paid — restore access"** as the user-facing safety net, plus the price list staying public so the paywall can't render blank | [paywall_screen.dart:77](lib/screens/paywall_screen.dart#L77) |
| Phone↔agent binding is **1:1 and immutable** without two proofs, so entitlement can't be re-pointed at another agent id | [otp/index.ts:305](supabase/functions/otp/index.ts#L305) |
| RLS on every money table; only `plans` is anon-readable (it's a price list) | [schema_payments.sql:64](admin/schema_payments.sql#L64) |

---

## What's still open

**Deploy — none of the fixes are live.** They exist on disk only:

```
supabase functions deploy pay              --use-api
supabase functions deploy groq             --use-api
supabase functions deploy razorpay-webhook --use-api --no-verify-jwt
```

Plus the dashboard (Vercel) for the repair control, and an app patch/release for
the two client changes ([razorpay_checkout.dart](lib/services/razorpay_checkout.dart),
[groq_client.dart](lib/assistant/groq_client.dart)). The new **Switching
payments on** section of [RUNBOOK.md](RUNBOOK.md) has the full order, including
the constraint that `otp_required` must go on *before* `payments_enabled`.

**P4c — reconciliation against Razorpay.** Deliberately not built: Razorpay is
still in test mode, so there is no real charge to reconcile, and building it
would mean putting `RAZORPAY_KEY_ID` / `RAZORPAY_KEY_SECRET` on the dashboard
host — today they live only in Supabase secrets. Revisit when going live: the
gap it would close is a charge that never reached us at all, which nothing in
our own data can see. Until then the manual repair control plus the runbook
procedure cover the failure modes we *can* detect.

**Unchanged by design:** the client paywall still fails open — locking a paying
agent out mid-round on flaky data is the worse failure, and P5's server-side
check is the backstop for that rather than a replacement. Refunds still don't
auto-revoke access; the difference is that the control the webhook's comment
points at now exists.
