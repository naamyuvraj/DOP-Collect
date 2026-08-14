# DOP Collect — Dashboard Data Runbook

How to make the admin dashboard show **complete, correct** user data. Do the
steps in order — later steps depend on earlier ones.

Supabase project ref: `ojorpmtptryldizogtkz` · App version: `0.9.48+20`

---

## Why a field is blank — the data map

Each column on the **Users** tab comes from a different place, so it needs a
different thing to be live:

| Field | Source | Needs |
|---|---|---|
| Agent, Version, Last seen, Status | `identify()` → `devices` | already working |
| **Verified** | live `device_sessions` row | already working (dashboard reads the session) |
| Region (SOL) / Agent ID | `agent_id` → `devices.sol_id` | already working |
| **Name** (display) | `devices.name` | ingest redeploy + app release + agent fills the **Name** field |
| **Mobile** | `devices.mobile` | `schema_accounts.sql` + ingest redeploy + app release |
| **Accounts** | `sync_done` event `{accounts}` | agent does a portal **Sync** |
| **Collected ₹** | `list_submitted` event `{amount}` | agent **submits a list** on the portal |
| Plan | `subscriptions` (by agent_id) | agent subscribes |

> The raw **mobile** is *only* stored if the app sends it — the OTP flow keeps
> just a hash. Verified status does **not** depend on `devices.phone_verified`
> anymore (the dashboard derives it from the session), so it's already correct.

---

## 1. Schema (mostly done — verify)

Run in the Supabase SQL editor if not already applied (all are `if not exists`
/ safe to re-run). Current DB already has the views + `devices.name/mobile`, so
this is a **verification** step:

```
admin/schema.sql              -- core analytics
admin/schema_management.sql   -- app_keys, app_config
admin/schema_ratelimit.sql    -- proxy_rate, bump_rate
admin/schema_otp.sql          -- accounts, device_sessions, otp_*
admin/schema_payments.sql     -- plans, subscriptions, payments
admin/schema_releases.sql     -- releases, v_app_versions
admin/schema_regions.sql      -- devices.agent_id/sol_id, v_regions
admin/schema_accounts.sql     -- devices.name/mobile, v_agent_accounts, v_accounts_summary
```

Quick check (SQL editor): `select id, name, mobile, agent_id, sol_id, phone_verified from public.devices limit 1;`
— it should run without a "column does not exist" error.

## 2. Set a real dashboard password (fixes login)

The hardened auth **rejects the default** `dopadmin` / `dev-secret`. If prod
still has them, login returns `not_configured`.

- **Vercel → Project → Settings → Environment Variables**: set a non-default
  `DASHBOARD_PASSWORD` and a long random `AUTH_SECRET`, then redeploy.
- Local `.env.local`: already set to a non-default value.

## 3. Redeploy the edge functions

The **deployed** `ingest` is stale (forwards `agent_id`/`sol_id` but not
`name`/`mobile`). `otp` should set `phone_verified`/`account_id` at the source.

Run these from the **repo root**. The CLI resolves `supabase/functions/` from the
current directory, so from anywhere else (`android/`, `dashboard/`) it fails with
`Entrypoint path does not exist` — and the 400 comes back from the server, which
makes it read like a project problem rather than a `cd`.

```
cd /Users/yuvrajmandal/Desktop/papa
supabase functions deploy ingest --use-api
supabase functions deploy otp    --use-api
```

`--use-api` avoids the local Docker bundler hang. `devices.mobile` already
exists, so the ingest upsert won't error.

## 3b. Release signing (do not skip — this is what stops updates wiping data)

Releases are signed with the upload keystore at `android/upload-keystore.jks`
(PKCS12, RSA-4096, alias `upload`, valid to 2053), configured through
`android/key.properties`. Both are git-ignored; neither is recoverable if lost.

Both commands run from the **repo root**. `apksigner` ships inside the Android
SDK build-tools and is not on `PATH`, so resolve it rather than calling it bare:

```
# Confirm the release variant uses the upload key, not the debug key.
(cd android && ./gradlew :app:signingReport -PrequireReleaseSigning=true)

# Confirm a built APK actually carries it.
"$(ls ~/Library/Android/sdk/build-tools/*/apksigner | sort -V | tail -1)" \
  verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# Expect: CN=DOP Collect  /  SHA-256 e9a34af8a05a1b38fd891b17c50801cf87871b51820202d22d1b32993adbe224
```

(`apksigner` on a recent JDK prints several `WARNING: A restricted method…`
lines before the certificate block. They are noise — read the `Signer #1` lines.)

> **Why this matters.** Android refuses to install an APK over one signed with a
> different key. Before this keystore existed the release build fell back to
> `~/.android/debug.keystore`, which is per-machine and regenerates — so a
> release built on another machine could not install over the previous one, and
> the agent had to uninstall. Uninstall wipes app-private storage, which is the
> ONLY copy of the `collections` ledger and the `lots` lists (see
> `lib/data/database.dart`). Losing this keystore re-creates that failure
> permanently. **Back up `upload-keystore.jks` + its password offline now.**
>
> **One-time cutover cost.** The first upload-signed APK still cannot install
> over an existing debug-signed install — those phones must uninstall, and their
> local data does not survive it. Accounts come back with a portal Deep Sync;
> the collections ledger, the lists, and `route_order`/`daily_amount`/`status`
> do not. Land an export/restore path before pushing this to a phone that holds
> real data.
>
> **`ANDROID_ID` changes with the signing key.** It is scoped per app-signing
> key, and `DeviceIdentity._derive` (`lib/services/device_identity.dart:97`)
> hashes it into the device id. Every existing phone therefore reports a NEW
> device id after the cutover and burns a fresh slot against the 3-phone limit;
> the old row lingers as a ghost. Anything keyed on device id — including any
> future restore path — must key on the DOP agent id instead.

## 4. Ship the app release

The deployed app sends `agent_id`/`sol_id` but not `name`/`mobile`. Ship the
current build so `identify()` sends them.

```
# OTA patch (Dart-only change). On a patch bump buildVersion ONLY (+22 -> +23);
# pubspec stays pinned to the release the patch attaches to.
shorebird patch android -- --dart-define-from-file=env.json --no-tree-shake-icons

# New release (native deps changed). Bump pubspec AND buildVersion together.
shorebird release android -- --dart-define-from-file=env.json --no-tree-shake-icons
```

> **`--dart-define-from-file=env.json` is not optional.** `SupabaseConfig.url`
> and `anonKey` are `String.fromEnvironment`, so they are resolved at COMPILE
> time. Build a patch without the flag and they compile to empty strings,
> `SupabaseConfig.configured` turns false, and every cloud call in the app
> silently short-circuits — paywall, OTP, remote config, analytics and the cloud
> assistant all go dead on every device that takes the patch. Nothing crashes
> and nothing logs; screens just come up empty.
>
> To check a patch landed correctly: open the dashboard **Devices** tab and
> confirm `last_seen` is still moving. If it froze the moment you patched, the
> flag was missing — re-patch with it.

Onboarding note: **Name** (display) and **Agent Name** are two different fields.
The agent must fill **Name** for the Name column to populate; the mobile is
captured from the phone they verify.

## 5. Verify (in the app + dashboard)

1. In the app: complete onboarding (Name + phone OTP) → **run a Sync** → build &
   **submit a list** on the portal.
2. On the dashboard **Users** tab, that agent should now show: Name, Mobile,
   Region, **Verified**, **Accounts** (after sync), **Collected ₹** (after a
   submitted list).
3. **Overview** → "Accounts under management" and "Total collected ₹" update.

---

## Switching payments on

Order matters here. `payments_enabled` is the last switch, not the first.

```
supabase functions deploy pay              --use-api
supabase functions deploy groq             --use-api
supabase functions deploy razorpay-webhook --use-api --no-verify-jwt
```

`--no-verify-jwt` on the webhook only — Razorpay sends no Supabase auth. Getting
that wrong makes every event 401 and the whole fallback path silently dead.

1. **Run `admin/schema_payments.sql`.** Without the `orders` table, `pay` now
   refuses to hand out an order (`not_recorded`, 500) rather than letting an
   agent pay for something nothing can activate. A blank paywall at this point
   means the schema hasn't been run.
2. **Set the secrets:** `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` on the `pay`
   function, and `RAZORPAY_WEBHOOK_SECRET` on **both** the webhook function and
   the Razorpay dashboard's webhook config. They must be the same string.
3. **Prove the webhook works before you need it.** With no secret set, or the
   wrong one, it rejects every event with a 400 and no alert — and it is the
   thing that saves an agent whose app died right after paying. Send a test
   event from the Razorpay dashboard and confirm a 200 in the function logs.
4. **Turn `otp_required` ON first.** Entitlement is keyed to the DOP agent id,
   which `pay` and `groq` read from the device session — no session, no identity,
   no paywall. `pay` fails open (nobody is blocked, the paywall just does
   nothing), so this is silent if you get it backwards.
5. **Run `admin/backfill_trials.sql` — before the flip, not after.** While
   payments are off, `pay` hands out an *ephemeral* trial and persists nothing;
   the moment the switch flips it starts writing real rows, so every existing
   agent would be granted a fresh full trial and first revenue would be one
   trial length away. The script writes an already-expired row for every agent
   that exists now, so only genuinely new agents get a trial. It has a dry-run
   query at the top — read the count first. Run it **after** the flip and it
   quietly misses exactly the agents it was meant to catch, because they will
   already have created their own trial rows.
6. **Then flip `payments_enabled`** (dashboard → Plans). Everything above is
   inert until this moment, including the server-side entitlement check in
   `groq`.
7. **Buy one real plan end to end** on a live device. Check `payments`,
   `orders`, `subscriptions` all gained a row and the app's banner moved.

### When an agent says they paid and have no access

1. Dashboard → **Payments** → is their payment listed as `success`?
2. Function logs (`pay` and `razorpay-webhook`) — grep for the payment id. The
   three that mean "money taken, access not granted" are:
   `subscription not extended`, `activate_failed`, `stranded`. Each logs the
   agent id and plan.
3. Fix it: dashboard → **Plans** → **Subscribers** → `+30d` on their row, or
   type the agent id into the **Grant** box if they have no row at all. Granted
   days stack exactly like a purchase, and land in Transactions as a `manual`
   row (excluded from revenue).
4. If the payment isn't in `payments` at all, it never reached us — check the
   Razorpay dashboard for the charge before granting anything.

---

## Reset (optional, destructive)

To wipe all telemetry + verification state and track only new verified users:
run `admin/reset_user_data.sql` in the SQL editor. **Keeps** plans / app_config /
subscriptions / payments. After a reset, Accounts/Collected read 0 until agents
sync again.
