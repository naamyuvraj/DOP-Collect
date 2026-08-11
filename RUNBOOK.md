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

```
supabase functions deploy ingest --use-api
supabase functions deploy otp    --use-api
```

`--use-api` avoids the local Docker bundler hang. `devices.mobile` already
exists, so the ingest upsert won't error.

## 4. Ship the app release

The deployed app sends `agent_id`/`sol_id` but not `name`/`mobile`. Ship the
current build so `identify()` sends them.

```
# bump pubspec.yaml version AND lib/services/supabase_config.dart buildVersion together, then:
shorebird patch android -- --no-tree-shake-icons     # Dart-only change → OTA patch
# (use `shorebird release android -- --no-tree-shake-icons` if native deps changed)
```

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

## Reset (optional, destructive)

To wipe all telemetry + verification state and track only new verified users:
run `admin/reset_user_data.sql` in the SQL editor. **Keeps** plans / app_config /
subscriptions / payments. After a reset, Accounts/Collected read 0 until agents
sync again.
