# Security hardening for the Play Store launch

The app ships the Supabase **anon key** in the APK — anyone can extract it. This
is the plan to make that harmless, without OTP.

## Threat model (what the anon key can/can't do)

| Vector | Risk | Status |
|---|---|---|
| Read customer data from Supabase | — | **None** — customer data is on-device (SQLCipher). Anon has no SELECT on data. |
| Drain Groq/LLM quota ($) | High | Rate-limited per device + IP in the `groq` function. ✅ |
| Spam OTP sends ($) | High | Rate-limited per phone/device in the `otp` function. ✅ (when live) |
| Forge `payments` rows | Med | **Fixed** — anon insert dropped; app never writes payments from client. |
| Spam `events`/`devices` | Low | **Fixed** — routed through the rate-limited `ingest` function; anon writes dropped. |
| Scripted/bot/repackaged-app abuse | Med | **Play Integrity** (below) — release-build task. |

Net after this work: **the anon key can only READ `app_config`.** All writes go
through rate-limited service-role edge functions.

## Done now (shippable)

1. **`ingest` edge function** — the only telemetry writer. Rate-limits (300/min,
   5000/day per device; 3000/hr per IP), truncates fields, writes with the
   service role.
2. **App** — `Analytics` posts to `ingest` instead of inserting directly.
3. **`admin/schema_harden.sql`** — drops the anon insert/update policies on
   `events`, `devices`, `key_usage`, `payments`.

### Deploy order (don't lock out live installs)
```bash
supabase functions deploy ingest --project-ref ojorpmtptryldizogtkz   # 1
# 2. ship the app patch (telemetry now routes through ingest)
# 3. after the patch has propagated, run admin/schema_harden.sql in SQL Editor
```

## Play Integrity — the anti-bot gate (do at the Play Store release)

The real defense against scripted abuse of a public app: prove each sensitive
call comes from a **genuine, unmodified install of your app on a real device**.
This is invisible to real users and stronger than OTP for *security*.

**Already in place:** a `require_integrity` config flag (default **false**) and a
fail-closed check in `groq` + `ingest` (`x-integrity-token` header). Flip the flag
on only after the steps below ship.

**To enable (needs the app on Play Console + a full APK release):**
1. **Play Console → App integrity** → enable the Play Integrity API; link a
   **Google Cloud project**; create a **service account** with Play Integrity
   access. Add its JSON as the `GOOGLE_SA` Supabase secret.
2. **App (native, full release — not a Shorebird patch):** add a Flutter Play
   Integrity plugin; request a token (Standard request, hashed with the request
   body); attach it as `x-integrity-token` on `groq`/`ingest`/`otp` calls.
3. **Edge functions:** implement `verifyIntegrity(token)` — call
   `playintegrity.googleapis.com/v1/<package>:decodeIntegrityToken` with the
   service account, and require `appRecognitionVerdict = PLAY_RECOGNIZED` +
   `deviceRecognitionVerdict` OK.
4. Set `app_config.require_integrity = true`.

Because Play Integrity needs the native plugin, it rides the **Play Store release
build**, alongside (later) the OTP SMS auto-read plugin.

## Not needed for launch

- **OTP / phone verification** — a *licensing/anti-sharing* layer, not security.
  The DOP portal login already gates real use (no agent credentials → dead app).
  Add it later behind `otp_required` for licensing.
