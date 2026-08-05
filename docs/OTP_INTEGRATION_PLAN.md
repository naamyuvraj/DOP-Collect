# OTP + phone-bound account licensing — integration plan (MSG91)

Phone-number OTP that **binds one phone ↔ one DOP account**, allows the account
on **at most 2 devices** (a 3rd signs the oldest out), auto-reads the SMS code,
and attributes **payments** to the verified account. Built on the existing stack
(Flutter + Supabase edge functions + admin dashboard + `RemoteConfig`).

---

## 1. Finalised requirements

1. **1 phone ↔ 1 DOP account** — a phone number links to exactly one DOP Agent
   ID, and that Agent ID to exactly one phone (bidirectional unique).
2. **Max 2 devices** per account. A login on a 3rd device revokes the **oldest**
   session → that device is "signed out" on its next check.
3. **Track payments** against the verified account (across its ≤2 devices).
4. **Auto-read the OTP** (Android SMS Retriever) → accepts a **native plugin**,
   so this ships as a **full APK release, not a Shorebird patch**.

The DOP portal login (Agent ID + password) is unchanged; OTP adds the identity +
licensing layer on top.

---

## 2. Architecture — server is the authority

The 2-device limit and 1:1 binding **must** be enforced server-side (a client
can't be trusted to sign itself out). A **Supabase edge function**
(`supabase/functions/otp`) holds the MSG91 auth key and owns all identity/session
state. Mirrors the existing `groq` proxy.

```
Flutter (OtpService / SessionGuard)
   │  anon key + session token
   ▼
Supabase edge fn `otp`  ── authkey ──▶  MSG91 v5 (send/verify/retry)
   │  (service role)
   ▼
accounts · device_sessions · payments   (Postgres, RLS-locked)
```

---

## 3. MSG91 prerequisites (external, some take days)

1. MSG91 account → **Auth Key**.
2. **DLT registration**: entity + header/sender ID (e.g. `DOPCOL`). Days.
3. **DLT-approved OTP template** → **`template_id`**, e.g.
   `Your DOP Collect code is ##OTP##. Do not share it. <app-hash>`
4. **App hash** appended for SMS Retriever auto-read (one per signing key).
5. SMS credits (+ optional voice-OTP fallback).

> Build behind `otp_required=false` now; go live only after the template is
> approved and secrets are set.

Secrets (Supabase → Edge Functions → Secrets):
`MSG91_AUTHKEY`, `MSG91_TEMPLATE_ID`, `MSG91_SENDER`, `SESSION_SIGNING_SECRET`.

---

## 4. Data model

Privacy-first: the raw phone only transits to MSG91; we store a **SHA-256 hash**.

```sql
-- One verified account per phone; bound 1:1 to a DOP Agent ID.
create table if not exists public.accounts (
  id           uuid primary key default gen_random_uuid(),
  phone_hash   text unique not null,          -- sha256(91xxxxxxxxxx)
  agent_id     text unique,                    -- DOP portal login (1:1)
  created_at   timestamptz not null default now(),
  disabled     boolean default false           -- admin kill switch per account
);

-- Active device sessions. Max 2 non-revoked per account (enforced in the fn).
create table if not exists public.device_sessions (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid references public.accounts(id) on delete cascade,
  device_id    text not null,
  token_hash   text not null,                  -- sha256(session token)
  app_version  text,
  created_at   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  revoked_at   timestamptz,                    -- set when kicked out
  revoked_reason text                          -- 'device_limit' | 'admin' | 'logout'
);
create index if not exists idx_sessions_account on public.device_sessions (account_id) where revoked_at is null;
create unique index if not exists uq_sessions_account_device on public.device_sessions (account_id, device_id);

-- OTP attempts: rate-limit + audit (no raw phone, no code).
create table if not exists public.otp_requests (
  id bigint generated always as identity primary key,
  device_id text, phone_hash text not null, req_id text,
  action text not null, status text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_otp_phone_time on public.otp_requests (phone_hash, created_at);

-- Payments attributed to the ACCOUNT (extends existing table).
alter table public.payments add column if not exists account_id uuid references public.accounts(id);

alter table public.accounts        enable row level security;
alter table public.device_sessions enable row level security;
alter table public.otp_requests    enable row level security;
-- No anon policies on any of these → only the edge function (service role) touches them.
```

`devices` also gets `phone_verified boolean`, `account_id uuid` for the Users &
Devices view.

---

## 5. The 2-device session model (the heart of it)

### On successful **verify**
1. Upsert `accounts` by `phone_hash`; on first bind, set `agent_id`.
   - Reject if the phone is already bound to a **different** `agent_id`, or the
     `agent_id` is already bound to a **different** phone → error
     `already_linked` (with a support path to transfer).
2. Create a `device_sessions` row for this `device_id`; mint a random
   **session token**, store only its hash.
3. **Enforce the cap**: if the account now has > 2 non-revoked sessions, revoke
   the **oldest** (`revoked_reason='device_limit'`). (Configurable: kick-oldest
   vs. block-new — default kick-oldest so a replaced phone just works.)
4. Return `{token, accountId}`. App saves the token in the **Keystore**
   (`flutter_secure_storage`, alongside the DOP creds).

### Ongoing enforcement — heartbeat
- App calls `session/check {token, deviceId}` on **app_open**, after each sync,
  and every ~30 min while active.
- Edge fn: token hash matches a **non-revoked** session → `{ok:true}` and bumps
  `last_seen`. Otherwise `{ok:false, reason}`.
- On `ok:false` the app runs **session-out**: clear the token, drop to a
  "Signed out — this account is now active on 2 other phones. Verify again to use
  it here." screen (re-entry via OTP, which will kick the current oldest).
- Fail-open on network error (never sign out just because the check couldn't
  reach the server); only an explicit `revoked` response signs out.

### Session list / remote sign-out
Dashboard can list an account's active devices and force-revoke one
(`revoked_reason='admin'`) — support tool for lost/stolen phones.

---

## 6. API contract (`/functions/v1/otp`)

`POST`, header `Authorization: Bearer <anon key>`:

| action          | request                                    | response                                   |
|-----------------|--------------------------------------------|--------------------------------------------|
| `send`          | `{action:"send", phone, deviceId}`         | `{ok, reqId, cooldown}`                     |
| `resend`        | `{action:"resend", phone, deviceId, via}`  | `{ok, cooldown}`                            |
| `verify`        | `{action:"verify", phone, otp, deviceId, agentId, appVersion}` | `{ok, token, accountId}` / `{ok:false, code:"already_linked"|"invalid_otp"|"expired"}` |
| `session/check` | `{action:"session_check", token, deviceId}`| `{ok:true}` / `{ok:false, reason:"device_limit"|"admin"|"unknown"}` |
| `logout`        | `{action:"logout", token, deviceId}`       | `{ok}` (revokes this session)               |

Edge fn ⇄ MSG91 v5 (unchanged): Send
`POST control.msg91.com/api/v5/otp?template_id=…&mobile=91…&otp_length=6&otp_expiry=10`,
Verify `GET …/api/v5/otp/verify?mobile=…&otp=…`, Resend `GET …/api/v5/otp/retry?…&retrytype=text|voice`,
all with header `authkey`.

---

## 7. Payments tracking

- Add `account_id` to `payments`; the app includes its `accountId` when it
  records a payment, so revenue rolls up **per account** (across both devices),
  not per install.
- Gate payments to **verified accounts** only (a paid plan belongs to a person,
  not a device — survives phone swaps within the 2-device rule).
- Portal RD collections (`list_submitted`) can optionally carry `account_id` too,
  so the dashboard shows collections **per agent**.
- Dashboard: an **Accounts** view (phone-hash, agent id, devices, verified date,
  lifetime collected, payments) + per-account drill-down.

---

## 8. Remote config (dashboard-controlled, via `RemoteConfig`)

| key             | default | meaning                                            |
|-----------------|---------|----------------------------------------------------|
| `otp_required`  | `false` | Gate onboarding on verification. Flip on post-DLT. |
| `max_devices`   | `2`     | Active devices per account.                        |
| `device_policy` | `kick_oldest` | vs `block_new` on the (N+1)th device.        |
| `otp_cooldown`  | `30`    | Resend cooldown (s).                               |
| `otp_max_send`  | `5`     | Sends per phone per hour.                           |
| `session_ttl`   | `43200` | Heartbeat re-check window (s).                      |

Add an "OTP & device limit" card to the dashboard **Config** page.

---

## 9. Flutter implementation

- **`lib/services/otp_service.dart`** — send/verify/resend + phone normalise.
- **`lib/services/session_guard.dart`** — holds the token (Keystore), runs the
  heartbeat, exposes a `signedOut` stream the shell listens to.
- **`lib/screens/otp_screen.dart`** — phone entry (`+91`, big numeric field) →
  6-box code with live resend countdown; bilingual, thick-finger sized.
- **Auto-read**: `smart_auth` (SMS Retriever, no read permission; needs the app
  hash in the DLT template). **Native → full release.**
- **`lib/screens/signed_out_screen.dart`** — the 2-device "signed out" state.
- **`lib/data/app_settings.dart` / secure storage** — token, phone hash,
  verified flag, account id.
- **`lib/screens/onboarding_login.dart`** — OTP step when `otp_required`, after
  Agent ID/password, binds phone↔agent on verify.
- **`lib/shell.dart` / `main.dart`** — start `SessionGuard`; on `signedOut` route
  to the signed-out screen.
- **Settings** — "Manage devices" (list this account's active phones) + "Change
  number" (re-verify/transfer).

---

## 10. Onboarding & enforcement flow

```
Agent ID + password
      │  (otp_required)
Phone entry ─▶ Send ─▶ auto-read / enter code ─▶ verify(agentId)
      │  ok: bind phone↔agent, mint token, enforce ≤2 devices
Name · ASLAAS · photo ─▶ Done
      │
Every app_open / sync ─▶ session/check ─▶ revoked? ─▶ Signed-out screen
```

---

## 11. Security

- Auth key + signing secret: **Supabase secrets only**, never in the app.
- All binding/limit logic **server-side**; the app can't self-authorise.
- Session token random, **stored hashed** server-side, in **Keystore** on device.
- Phone stored **hashed**; raw number only to MSG91. OTP code never logged.
- Heartbeat **fails open** on network error (works offline), signs out only on an
  explicit `revoked`.
- Admin per-account **disable** + per-session **revoke** kill switches.

---

## 12. Abuse & cost control

Resend cooldown, ≤`otp_max_send`/phone/hour, ≤N/device/day, ≤5 verify tries per
`reqId` then lock. Reuse `admin/schema_ratelimit.sql`.

---

## 13. Analytics (privacy-safe, no phone/code)

`otp_sent`, `otp_verified`, `otp_failed{reason}`, `otp_resend{via}`,
`device_kicked{reason}`, `signed_out{reason}` → verification funnel + a
"device-limit hits" metric on the dashboard.

---

## 14. Edge cases

Phone swap (new device kicks oldest — just works) · same person re-verifying
(refresh, no extra session) · `already_linked` (wrong Agent ID on a bound phone →
clear error + support/transfer) · dual-SIM / wrong number · MSG91 outage
(`provider_down`) · auto-read miss → manual entry always available · offline
(heartbeat fails open).

---

## 15. Rollout

1. Build behind `otp_required=false` (edge fn + schema + UI + native autofill in
   a **full release**). No user impact.
2. DLT + template approved, secrets set, test numbers.
3. Soft launch: `otp_required=true` — watch the funnel + device-limit hits.
4. Enforce; keep `otp_required` as the instant kill switch.

---

## 16. Effort estimate

| Piece                                              | Est.    |
|----------------------------------------------------|---------|
| Edge fn (send/verify/resend + binding + 2-device)  | ~2 days |
| Schema (accounts/sessions/otp + payments attr)     | ~½ day  |
| SessionGuard + heartbeat + signed-out UX           | ~1 day  |
| OtpService + OTP screen + SMS auto-read (native)   | ~1.5 day|
| Onboarding + Settings "manage devices"             | ~1 day  |
| Dashboard Accounts view + remote sign-out          | ~1 day  |
| DLT/template/secrets (calendar)                    | days    |

Dev ≈ **6–7 focused days** + a **full APK release** (native autofill). DLT is the
long pole.
