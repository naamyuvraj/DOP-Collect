# Razorpay setup — DOP Collect subscriptions

Plain, direct steps to connect Razorpay to the payments we already built. You
have an existing Razorpay account (used for an e-com app ~1 year ago, now
dormant) — this is written for **reusing that account**, not making a new one.

---

## 1. What we use (and don't)

**Use:**
- **Standard Checkout** (the Razorpay payment sheet) via the `razorpay_flutter` plugin.
- **Orders API** — our server creates an order before checkout.
- **Payment Signature verification** — HMAC-SHA256 on our server.
- **API Keys** (Key Id + Key Secret), Test then Live.
- **Webhooks** (recommended) for reliable confirmation.

**Do NOT use / not needed:**
- Razorpay **Subscriptions / Plans** product (auto-debit eMandate). We do
  **one-time Orders per period** (monthly/quarterly/yearly), manual renewal —
  simpler, no eMandate friction. (Auto-renew is a future option.)
- Magic Checkout, Razorpay Route, Payment Links, Payment Pages.

**Three keys map like this:**
| Key | Where it lives | Used for |
|---|---|---|
| `RAZORPAY_KEY_ID` | Supabase secret **+** sent to app in the order response (public, safe) | opens checkout |
| `RAZORPAY_KEY_SECRET` | **Supabase secret ONLY — never in the app** | create order + verify signature |
| `RAZORPAY_WEBHOOK_SECRET` | Supabase secret (if webhooks) | verify webhook |

---

## 2. Your existing account — check these first

Since it's dormant, on [dashboard.razorpay.com](https://dashboard.razorpay.com) verify:

- [ ] **Login works** and the account isn't suspended/deactivated.
- [ ] **KYC status** = Activated (Account & Settings → look for "Activated" /
      no pending KYC banner). If you took **live** payments on the e-com app,
      KYC is already done and **Live mode is available** — you can skip the
      3-day website verification.
- [ ] **Bank account** on file is still correct (Settlements → this is where
      money lands). Update if the old one is closed.
- [ ] **Business/website details** — live activation needs a website OR app
      URL. For a mobile app, use your **Play Store listing URL** once published,
      or a simple business landing page. If they ask to re-verify, submit the
      Play Store URL.

> If the account was fully activated before, you likely just generate fresh
> keys and go. If it was reverted to test-only, you'll redo the website
> verification (~3 working days).

---

## 3. Razorpay Dashboard — generate API keys

Path: **Account & Settings → API Keys** (under "Website and app settings").

**Test keys (do this NOW — no KYC, no website needed):**
- [ ] Toggle the dashboard to **Test Mode** (top of screen).
- [ ] API Keys → **Generate Test Key**.
- [ ] A popup shows **Key Id** (`rzp_test_…`) and **Key Secret**. **Copy both
      now** — the secret is shown only once.

**Live keys (after KYC/website is confirmed):**
- [ ] Switch to **Live Mode** → **Generate Live Key** → copy `rzp_live_…` + secret.
- [ ] ⚠️ Generating a new live key **invalidates the previous** live key pair.
      Your old e-com app isn't running, so this is safe — just don't do it while
      anything else depends on the old keys.

---

## 4. Supabase — set the secrets

Our `pay` edge function is already deployed and reads these. Set the **test**
keys first:

```bash
supabase secrets set \
  RAZORPAY_KEY_ID=rzp_test_xxxxxxxx \
  RAZORPAY_KEY_SECRET=xxxxxxxxxxxxxxxx \
  --project-ref ojorpmtptryldizogtkz
```

That's it — `order` and `verify` go live immediately (in test mode). Swap to
`rzp_live_…` for production. No redeploy needed after setting secrets.

---

## 5. App (release build only — native plugin)

The checkout sheet is native, so it ships in the **Play Store release**, not a
Shorebird patch. We left a clean seam (`Subscription.opener`).

- [ ] `flutter pub add razorpay_flutter`
- [ ] Implement the opener: create a `Razorpay()`, listen for
      `EVENT_PAYMENT_SUCCESS` / `ERROR` / `EXTERNAL_WALLET`, call
      `.open({ key, order_id, amount, currency, name, prefill })`, and on
      success return `{order_id, payment_id, signature}` to `Subscription`.
- [ ] Set `Subscription.opener = <that function>` at startup.
- [ ] Android: minSdk 21+, add the Razorpay ProGuard rules (from their docs) if
      you enable code shrinking.

Everything before the sheet (plans, order creation, verify, paywall UI, the
gate) already works today.

---

## 6. The payment flow (already coded)

```
App: tap a plan
 → pay(order)      server creates Razorpay Order (secret)  → orderId + keyId
 → razorpay_flutter opens checkout with orderId            → user pays
 → Razorpay returns order_id + payment_id + signature
 → pay(verify)     server HMAC-checks signature (secret)
        ok → extends subscription (+plan days), records payment → access unlocked
```

Signature check (server): `HMAC_SHA256(order_id + "|" + payment_id, KEY_SECRET)`
must equal `razorpay_signature`. This is implemented in `supabase/functions/pay`.

---

## 7. Webhooks (recommended — reliability)

The app's `verify` call confirms most payments, but if the app is killed right
after paying, you'd miss it. A webhook makes the server the source of truth.

On the dashboard: **Account & Settings → Webhooks → Add New Webhook**
- [ ] **URL:** `https://ojorpmtptryldizogtkz.supabase.co/functions/v1/razorpay-webhook`
- [ ] **Secret:** make one up, save it as `RAZORPAY_WEBHOOK_SECRET` in Supabase.
- [ ] **Events:** `payment.captured` (and optionally `order.paid`).
- [ ] The webhook function verifies `HMAC_SHA256(rawBody, WEBHOOK_SECRET)` ==
      the `X-Razorpay-Signature` header, then activates the subscription.

> ✅ **Built + deployed** (`supabase/functions/razorpay-webhook`). To turn it on:
> 1. Pick a secret, set it in Supabase:
>    `supabase secrets set RAZORPAY_WEBHOOK_SECRET=<secret> --project-ref ojorpmtptryldizogtkz`
> 2. Razorpay dashboard → **Settings → Webhooks → Add New Webhook**:
>    URL `https://ojorpmtptryldizogtkz.supabase.co/functions/v1/razorpay-webhook`,
>    same **secret**, events **`payment.captured`** (+ `order.paid`), Active.
> The webhook and the app's `verify` are idempotent — whichever lands first
> activates, the other no-ops.

---

## 8. Testing (test mode)

- Use test cards from Razorpay docs, e.g. **card `4111 1111 1111 1111`**, any
  future expiry, any CVV, any name; OTP `1234` / success on the test page.
- UPI test: `success@razorpay`.
- No real money moves in test mode.

---

## 9. Money — settlements & fees

- **Settlements:** collected money settles to your linked bank account on a
  rolling cycle (default **T+2 working days**). Configure in Settings →
  Settlements.
- **Fees:** Razorpay charges roughly **2% + GST** per successful transaction
  (varies by method/plan). Factor this into your plan prices.

---

## 10. Go-live checklist

- [ ] Existing account active; KYC = Activated; bank account correct.
- [ ] Test keys set in Supabase → test the full flow end to end.
- [ ] `razorpay_flutter` opener implemented + set in the release build.
- [ ] Real plan prices set in the `plans` table (dashboard/SQL).
- [ ] (Recommended) webhook added.
- [ ] Live keys set in Supabase (swap test → live).
- [ ] Flip `app_config.payments_enabled = true` (from the dashboard Config page).

---

## 11. What's already done (so you know the boundary)

- ✅ `pay` edge function (order + verify) — deployed.
- ✅ `schema_payments.sql` (plans, subscriptions, views) — run it in SQL Editor.
- ✅ App: subscription service, paywall UI, trial, access gate — shipped (inert).
- ✅ Dashboard: Plans + Subscribers + revenue on the Payments page; paywall toggle.
- ⏳ You: Razorpay keys → Supabase secrets · native opener in the release ·
  (optional) webhook · flip the flag.
