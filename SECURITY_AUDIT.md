# DOP Collect — Security Audit (end-to-end)

**Date:** 11 August 2026 · supersedes the 30 July 2026 audit
**Scope:** Flutter app (`lib/`), Android build + manifest (`android/`), Supabase edge functions (`supabase/functions/`), DB schemas + RLS (`admin/`), Next.js admin dashboard (`dashboard/`), repo hygiene.
**Threat model:** A DOP agent's phone holds live India Post banking credentials and the PII of 300–800 customers. Adversaries: (a) on-path attacker on shared/village Wi-Fi, (b) a malicious app on the same device, (c) anyone with the APK who extracts the embedded anon key, (d) accidental exposure of operator tooling, (e) abuse of the public edge functions.

---

## Severity legend

| Tag | Meaning |
|---|---|
| 🔴 CRITICAL | Directly yields live banking credentials or full backend control |
| 🟠 HIGH | Significant exposure of credentials, money, PII, or app integrity |
| 🟡 MEDIUM | Meaningful weakening of a control; fix before/at launch |
| 🔵 LOW / INFO | Hardening gap or accepted risk worth recording |

## Findings at a glance

| ID | Sev | Finding | Status |
|---|---|---|---|
| **A1** | 🟠 HIGH | Admin dashboard: weak default password + static session token, no login throttle | ✅ **fixed** (set real env vars) |
| **A2** | 🟠 HIGH | Release builds are **debug-signed** until a real upload keystore exists | open (launch blocker, ops) |
| **A3** | 🟠 HIGH | `service_role` key rotation still pending (was in cleartext on disk) | open (user action) |
| **A4** | 🟡 MED | **OTP send has no per-IP / per-device cap** → phone-enumeration + WhatsApp-cost spam | ✅ **fixed** (redeploy done) |
| **A5** | 🟡 MED | `otp` function has **no Play-Integrity gate** (pay/groq/ingest do) | ✅ **fixed** |
| **A6** | 🟡 MED | Play Integrity dormant → rate limiting is the only anon-key abuse control | open (launch) |
| **A7** | 🟡 MED | `RECORD_AUDIO` permission present — remove if voice input isn't shipping | open (product decision) |
| **A8** | 🔵 LOW | WebView navigation allowlist removed (portal compat) — origin gate is now the sole WebView control | accepted |
| **A9** | 🔵 LOW | OTP stored as unsalted `sha256(phone:otp)`; verify compare not constant-time | ✅ **fixed** (salted + timing-safe) |
| **A10** | 🔵 INFO | `genOtp` has slight modulo bias | ✅ **fixed** (rejection sampling) |
| **A11** | 🔵 LOW | No obfuscation / R8 minification | deferred |
| **A12** | 🔵 INFO | Native `restart` MethodChannel is in-process only | accepted |

> **Fix pass (11 Aug):** A1, A4, A5, A9, A10 done. Remaining: A2/A3 (ops), A6 (launch),
> A7 (product decision), A8/A11/A12 (accepted/deferred). A1 needs strong `AUTH_SECRET`
> + `DASHBOARD_PASSWORD` env vars set (it now **fails closed** on the old defaults).

> **No open CRITICALs.** The July credential-theft chain (WebView autofill with no origin check + cleartext HTTP + debug signing) is closed on the first two; signing is A2.

---

# 🟠 HIGH

## A1. Admin dashboard — weak default auth guarding the `service_role` key

**Where:** [dashboard/app/api/auth/route.ts](dashboard/app/api/auth/route.ts), [dashboard/middleware.ts](dashboard/middleware.ts)

The dashboard holds the `service_role` key (bypasses all RLS — full read/write on `accounts`, `payments`, `app_keys`, everything). Its only gate is a single shared password, and:

- **Default password `"dopadmin"`** (`DASHBOARD_PASSWORD`) and **default `AUTH_SECRET "dev-secret"`** if the env vars aren't set in prod.
- The session cookie stores the **static secret itself** (`token === expected`) — same value for every session, so a stolen cookie can't be revoked and rotation logs everyone out.
- **No rate-limit / lockout** on `/api/auth` → the password is brute-forceable.
- Password compare is not constant-time (minor).

**Fix:** fail closed if `DASHBOARD_PASSWORD` / `AUTH_SECRET` are unset or equal the defaults; issue a **random per-session token** (not the raw secret) and store its hash; add a login attempt limiter. Confirm strong values are set on Vercel.

## A2. Release builds are debug-signed until a real upload keystore exists

**Where:** [android/app/build.gradle.kts](android/app/build.gradle.kts)

Without `android/key.properties`, the release APK is signed with the **debug keystore** (identical on every machine). The build now **warns loudly** and `-PrequireReleaseSigning=true` makes it throw — but the current shipped APKs (0.9.46+18) are still debug-signed. Anyone can strip, trojanize, and re-sign a debug-signed APK, and Android accepts it as an in-place update.

**Fix (at launch):** generate an upload keystore, always build production with `-PrequireReleaseSigning=true`, enroll in Play App Signing, and **back the keystore up offline** (losing it = you can never update the listing).

## A3. Rotate the `service_role` key

It lived in cleartext in `admin/keys.js` (now deleted, never committed to git ✅). Treat it as exposed: **roll it in Supabase**, update `dashboard/.env.local` + Vercel env, redeploy. Edge functions pick up the injected key automatically.

---

# 🟡 MEDIUM

## A4. OTP send has no global (per-IP / per-device) cap — enumeration + cost abuse *(new)*

**Where:** [supabase/functions/otp/index.ts](supabase/functions/otp/index.ts) (`send`/`resend`)

Send is limited **only per phone**: a 30s cooldown and `maxSendPerHour` (5) keyed on `sha256(phone)`. There is **no per-IP or per-device cap across different phones**. Anyone with the APK's anon key can iterate phone numbers and trigger up to 5 WhatsApp OTPs/hour to *each* — real money (WhatsApp template cost) and spam to arbitrary people. `groq`/`ingest`/`pay` all have a per-IP hourly backstop; `otp` does not.

**Fix:** add the same layered guard to `send`/`resend` — e.g. `bump("otpip:"+ip, 3600) > ~30` and `bump("otpdev:"+device, 3600) > ~10`, tunable from `otp_limits`.

## A5. `otp` function has no Play-Integrity gate *(new)*

`pay`, `groq`, and `ingest` all fail closed when `require_integrity=true`. The `otp` function does **not** check it, so even after Integrity is enabled, OTP send/verify stays open to any anon-key holder. Pairs with A4.

**Fix:** add the same `require_integrity` check to `otp` before `send`/`resend`/`verify`.

## A6. Play Integrity gate is dormant

**Where:** [pay](supabase/functions/pay/index.ts), [groq](supabase/functions/groq/index.ts), [ingest](supabase/functions/ingest/index.ts) — all gate on `require_integrity`, which defaults false. Until it's on (and real token verification is added — the current check only tests token *presence*), **rate limiting is the only control** on the public functions.

**Fix (launch):** wire real server-side token verification (decode via the Play Integrity API + verdict checks), then flip `require_integrity=true`. See the earlier Play-Integrity plan.

## A7. `RECORD_AUDIO` permission

**Where:** [AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) — for `speech_to_text` voice input. If voice isn't shipping day one, remove it: smaller attack surface and one less Play data-safety disclosure.

---

# 🔵 LOW / INFO

## A8. WebView navigation allowlist removed (accepted)

**Where:** [sync_screen.dart](lib/screens/portal/sync_screen.dart), [deep_sync_screen.dart](lib/screens/portal/deep_sync_screen.dart)

The `onNavigationRequest` host-allowlist broke the DOP portal's post-login window flow, so it was removed. The **primary control remains**: credential autofill is gated on `location.origin === 'https://dopagent.indiapost.gov.in'`, so creds are never typed/submitted off-portal. Residual: a foreign page *could* load in the WebView, but can't harvest credentials. Acceptable given the portal-compat constraint and HTTPS-only + system-trust-anchors network config.

## A9. OTP hash unsalted; verify compare not constant-time

`otp_codes` stores `sha256(phone:otp)` with no salt; a leak of that table would let a 4-digit code be brute-forced offline (10⁴ space). Mitigated: the table is service-role-only, the row is deleted on use/expiry, and there's a 5-try online cap. `verify` uses `!==` (not timing-safe) — not practically exploitable given the attempt cap. Low.

## A10. `genOtp` modulo bias (info)

`byte % 10` skews digits 0–5 slightly higher than 6–9. Negligible for a rate-limited 4-digit OTP; use rejection sampling if you want it clean.

## A11. No obfuscation / R8

`isMinifyEnabled=false` — portal URLs, selectors, and logic are readable in the APK. Solvable with ML-Kit keep-rules; deferred (also keeps the APK at ~114 MB).

## A12. Native `restart` MethodChannel (info)

**Where:** [MainActivity.kt](android/app/src/main/kotlin/com/dopcollect/dop_collect/MainActivity.kt) — the `dop_collect/app` channel's `restart` does launch-intent + `Runtime.exit(0)`. In-process only (not an exported component), so no other app can invoke it. No auth needed.

---

# ✅ Controls confirmed strong (don't regress)

| Control | Where |
|---|---|
| DOP credentials in the **Android Keystore** (`flutter_secure_storage`, `encryptedSharedPreferences`), plaintext legacy prefs migrated in **and wiped** | [credentials.dart](lib/data/credentials.dart) |
| **SQLCipher** DB with a `Random.secure()` 256-bit Keystore key; **crash-safe recovery** if the key is lost (moves file aside, re-syncs) | [database.dart](lib/data/database.dart) |
| Assistant SQL runs on a **read-only** SQLCipher handle behind `SqlGuard` | [database.dart](lib/data/database.dart), [sql_guard.dart](lib/assistant/sql_guard.dart) |
| **Origin-gated** credential autofill on the banking WebView; login auto-submit capped at 2 | [sync_screen.dart](lib/screens/portal/sync_screen.dart) |
| **HTTPS-only** (cleartext blocked everywhere) + **system-only** trust anchors (blocks user-CA mitm) | [network_security_config.xml](android/app/src/main/res/xml/network_security_config.xml) |
| **FLAG_SECURE** app-wide (no recents/screenshot/screen-record capture) | [MainActivity.kt](android/app/src/main/kotlin/com/dopcollect/dop_collect/MainActivity.kt) |
| WebView cookies cleared on logout; OTP session revoked server-side on logout | [settings_screen.dart](lib/screens/settings_screen.dart) |
| **allowBackup=false**, `fullBackupContent=false`, minimal permissions, one exported activity, `taskAffinity=""`, no deep links / exported providers | [AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) |
| **All anon writes dropped** — only rate-limited service-role edge functions write; anon reads a **key-allowlisted** `app_config` + `plans` | [schema_harden.sql](admin/schema_harden.sql), [schema_management.sql](admin/schema_management.sql) |
| Payments: **HMAC-SHA256 timing-safe** verify, plan derived from the **server-recorded order**, idempotent (unique payment ref), server-authoritative **webhook** with refund/failed handling | [pay/index.ts](supabase/functions/pay/index.ts), [razorpay-webhook/index.ts](supabase/functions/razorpay-webhook/index.ts) |
| OTP: only **SHA-256 hashes** of phone stored; 1 phone ↔ 1 agent; **max-2-device** sessions with remote revoke; layered per-phone rate limits | [otp/index.ts](supabase/functions/otp/index.ts) |
| Groq keys fully server-side; layered per-device + per-IP rate limits | [groq/index.ts](supabase/functions/groq/index.ts) |
| On-device captcha OCR (image never leaves the phone); the app never taps "Pay All" | [sync_screen.dart](lib/screens/portal/sync_screen.dart) |
| Repo hygiene — `key.properties`, `*.jks`, `keys.js`, `env.json`, `*.pdf`, `*.har` git-ignored; **clean history**; `pubspec.lock` committed | [.gitignore](.gitignore) |

---

# Remediation plan

## Before Play Store launch (blockers)
- [ ] **A2** — upload keystore + `-PrequireReleaseSigning=true` + Play App Signing + offline backup
- [ ] **A1** — dashboard: reject default creds, random per-session token, login throttle
- [ ] **A3** — rotate `service_role`

## At launch
- [ ] **A6 / A5** — real Play-Integrity verification, add the gate to `otp`, flip `require_integrity=true`
- [ ] **A7** — drop `RECORD_AUDIO` if voice isn't shipping

## This week (cheap, high-value)
- [ ] **A4** — per-IP + per-device cap on OTP send *(prevents WhatsApp-cost abuse)*

## Backlog / accepted
- [ ] **A11** — R8 + ML-Kit keep-rules + `--obfuscate --split-debug-info`
- [ ] **A9 / A10** — salt the OTP hash / constant-time compare / rejection-sampled OTP (nice-to-have)
- [x] **A8, A12** — accepted / informational

---

## Bottom line

The **at-rest and backend posture is strong** — Keystore creds, SQLCipher with recovery, origin-gated banking login, HTTPS-only, FLAG_SECURE, service-role-only writes, HMAC payments with server-side plan binding and idempotency, hashed OTP with device limits, layered rate limits, clean git history.

The open work is concentrated in **operations, not app code**: the dashboard's default auth (A1), the debug signing key (A2), and rotating the exposed `service_role` (A3) — all HIGH but all quick. The one genuinely new code gap is **A4/A5** — the OTP endpoint is missing the per-IP cap and integrity gate the other functions have, which is worth closing before OTP goes live so it can't be turned into a WhatsApp-cost spam cannon.
