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

## Stack
Flutter · SQLite (`sqflite`) · `webview_flutter` · `google_mlkit_text_recognition`
· `flutter_secure_storage` · Groq (assistant) · Supabase (anonymous analytics).

## Build
Secrets are injected at build time from a git-ignored `env.json`
(see `env.json.example`):

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
