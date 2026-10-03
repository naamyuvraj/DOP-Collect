# DOP Collect

A lightweight, offline-first Android app for an India Post **MPKBY recurring-deposit
collection agent**. It logs into the DOP agent portal, pulls the agent's RD
accounts, and helps track dues, build deposit lists, and answer questions — all
on-device.

## Features
- **One-touch Sync** — logs into the DOP agent portal (auto-fills ID/password,
  reads the captcha on-device with ML Kit) and pulls all RD accounts in ~1–2 min.
- **Dashboard** — first/second-half dues, defaulters, about-to-freeze, maturity,
  advanced-paid and new accounts, each drillable.
- **Groups & Lists** — build ₹20,000-capped deposit lots by hand, or auto-pack
  every due account into ready lists; print / share / WhatsApp; and prepare them
  on the portal automatically.
- **Interest Calculator** — maturity for RD, TD, MIS, SCSS, NSC, KVP, PPF,
  Sukanya and more, with editable, opening-date-aware rates.
- **AI Assistant** — ask about accounts, customers, dues, or post-office schemes
  in English or Hindi (text + voice). Local-first; the cloud tier only ever sees
  a PII-free schema, never customer data.
- **OTA updates** via Shorebird.

## Repository layout

```
app/            Flutter — the agent app. One codebase, two targets:
                the Android handset and the desktop web build (app/web/).
admin/          Next.js admin dashboard (analytics, users, releases). Port 3939.
backend/
  supabase/     Edge functions — the bridge between app, admin and Postgres.
  schema/       SQL schema and migrations, applied by hand.
customer-app/   Placeholder. The customer-facing app, not started.
docs/
  ops/          Runbook and scaling notes — how to ship and operate.
  audits/       Security, payments, sync and UX audits.
  plans/        Designs and handovers for work in progress.
  reference/    Portal internals, integration guides, privacy policy.
brand/          Logos and marks.
```

**Every Flutter and Shorebird command runs from `app/`,** not the repo root —
that is where `pubspec.yaml`, `shorebird.yaml` and the git-ignored `env.json`
live. Supabase CLI commands run from `backend/`, which is where the CLI finds
`supabase/functions/`.

```bash
cd app     && flutter test              # the agent app
cd admin   && npm run dev               # the dashboard
cd backend && supabase functions deploy <fn> --use-api
```

## Stack
Flutter · SQLite (`sqflite`) · `webview_flutter` · `google_mlkit_text_recognition`
· `flutter_secure_storage` · Groq (assistant) · Supabase (anonymous analytics).

## Build
Secrets are injected at build time from a git-ignored `env.json`
(see `app/env.json.example`):

```bash
cp env.json.example env.json     # then fill in your keys
flutter pub get
flutter build apk --release --dart-define-from-file=env.json --no-tree-shake-icons
```

Without keys the app still runs — the assistant's cloud tier and analytics
simply stay off.

## Privacy
Customer data (names, account numbers, amounts) never leaves the device.
Credentials are stored in the Android Keystore. The assistant has an
**Offline-only** mode and analytics is **anonymous with an opt-out**.

## Admin analytics
`admin/schema.sql` sets up Supabase; `admin/dashboard.html` is a self-contained,
themed dashboard (open locally with your service-role key).

---
Built by Yuvraj Mandal.
