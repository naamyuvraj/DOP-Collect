# DOP Collect — Admin Dashboard

Next.js 14 admin dashboard for DOP Collect: analytics, users/devices, activity,
API-key management, payments, and remote app config. The Supabase **service_role
key stays server-side only** (API routes / server components) — it never reaches
the browser.

## Setup
```bash
cd dashboard
cp .env.local.example .env.local     # fill in the values (see below)
npm install
npm run dev                          # http://localhost:3939
```

`.env.local`:
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` — Supabase → Settings → API.
- `DASHBOARD_PASSWORD` — the login password.
- `AUTH_SECRET` — a long random string (session cookie value).

## Supabase
Run in the SQL editor, in order:
1. `../admin/schema.sql` — analytics tables + views.
2. `../admin/schema_management.sql` — `app_keys` + `app_config`.

`.env.local` (optional, for the Assistant):
- `SYNAP_MCP_URL`, `SYNAP_TOKEN` — Maximem Synap memory. Without them the
  assistant still answers; it just won't remember across sessions.
- The assistant uses the Groq keys in the `app_keys` table (API Keys page). For
  local dev before any key is stored, set `GROQ_KEYS=gsk_a,gsk_b`.

## Pages
- **Assistant** — an analytics agent (Groq tool-calling + Maximem Synap memory).
  Ask in plain English about installs, activity, revenue, and key health; it
  fetches live numbers via a fixed set of read-only tools (never free-form SQL
  against the service_role key), remembers what you care about, and refuses PII.
- **Overview** — installs, active users, syncs, queries, revenue, charts.
- **Users & Devices** — every install with last-seen + status.
- **Activity** — the latest events.
- **API Keys** — live Groq key health + a managed key store (for a future proxy).
- **Payments** — revenue + transactions.
- **Plans** — edit subscription pricing/duration and roll plans out to every
  install with no app update: a master paywall switch (`payments_enabled`),
  per-plan Offered toggles (`plans.active`), trial length, and a subscriber list.
  The app reads plans live via the `pay` edge function, so changes take effect
  on the next refresh.
- **App Config** — feature flags, force-update, announcement banner (read by the
  app at runtime, no rebuild needed).

## Deploy (Vercel)
Point Vercel at the `dashboard/` directory and set the same four env vars in the
project settings. Auth + the service key both stay server-side.
