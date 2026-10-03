# DES — where DOP Collect stands

Catch-up doc for coming back after time away. Compiled 3 Oct 2026 from the git
history, the staged working tree and `docs/`. It is a map, not a spec — each
section points at the file that holds the detail.

Not verified: nothing was built, run or deployed to write this. Anything about
what is live on Supabase, Vercel or Shorebird is inferred from the repo, so
check it against the real consoles.

---

## 1. What this is

**DOP Collect** is an app for an India Post **MPKBY recurring-deposit
collection agent**. The agent carries a book of RD customers. Each month they
collect cash and file it with the post office in **₹20,000 lists**. The app
exists to cut that paperwork.

The DOP agent portal has no API, so the app drives it through a real WebView.
It autofills credentials from the Android Keystore, solves the captcha with
on-device ML Kit, walks about 47 pages and parses the rendered tables. Most
sync bugs have been timing races, not parsing errors.

Products in the repo:

| Product | Dir | State |
|---|---|---|
| Agent app (Android + desktop web) | `app/` | Live, shipping patches via Shorebird |
| Admin dashboard (Next.js, Vercel) | `admin/` | Live, large |
| Backend (Supabase edge fns + SQL) | `backend/` | Live, grew a new `sync` fn |
| Customer app | `customer-app/` | **Not started.** Placeholder README only |

---

## 2. What changed while you were away

### 2.1 Repo restructure (staged, NOT committed)

The root used to hold `dashboard/`, `supabase/` and a flat Flutter app. The
index now has:

```
app/            Flutter (was the repo root)
admin/          Next.js dashboard (was dashboard/)
backend/
  supabase/     edge functions + tests (was supabase/)
  schema/       SQL (was admin/*.sql)
customer-app/   placeholder
docs/{ops,audits,plans,reference}
brand/
```

- 390 files are staged, almost all renames. `HEAD` still has the old layout.
- `.gitignore` and `README.md` are updated for the new paths.
- Nothing has been committed since `443e14d` (25 Aug). Commit this as one
  "restructure" commit before anything else, so it is not mixed with feature work.
- Docs still use old paths (`dashboard/`, `supabase/functions/`, `admin/schema_*.sql`).
  `HANDOFF.md`, `SECURITY_AUDIT.md`, `RUNBOOK.md` and `admin/README.md` are
  stale on this point. The `admin/README.md` setup also says `cd dashboard`.
- `README.md` still has an "Admin analytics" section pointing at
  `admin/schema.sql` and `admin/dashboard.html`. Both moved or were removed.
- `app-debug.apk` (226 MB) and `dop-collect-1.0.0+44.apk` (79 MB) sit untracked
  in the root. Delete or ignore them. Do not `git add .`.

### 2.2 The shift to Supabase: the book now leaves the phone

Until mid-Aug Supabase held only telemetry, OTP sessions and payments. The
customer book (accounts, collections ledger, saved lists) lived only in the
phone's SQLCipher file. That was a deliberate privacy position.

**Decision (per Yuvraj):** the local mobile SQLite and the desktop version kept
conflicting, since each held its own copy of the book. The fix was to make
Supabase the single source of truth, with phone and desktop both syncing to it.
The repo only records the "desktop had nothing to show" half of this
(`schema_book.sql` header). The conflict history itself isn't written down
anywhere in the repo.

The local-only position has now been given up, to give a second device something
to show:

- `backend/schema/schema_book.sql` adds three tables for accounts, collections
  and lots.
  - RLS is on with **no policies**, so only the service role can touch them.
  - Every row carries `account_id`, a server-clock `updated_at` (the pull
    cursor) and a client-clock `client_updated_at` (the last-write-wins rule).
- `backend/supabase/functions/sync/index.ts` is a two-way push-then-pull
  endpoint.
  - The account id comes from the device session, never from the request body.
  - It deliberately has no Play Integrity gate, because the web build cannot
    attest.
  - The 2-device limit is enforced at OTP `verify`. A kicked device sees
    `no_session` on its next sync.
- `app/lib/services/cloud_sync.dart` is the client for it.
- **DOP portal credentials stay in the Keystore and are never uploaded.** That
  is the line that matters.
- Khata backup (`backup_service.dart`, `backup_format.dart`) is a separate
  AES-GCM file export. It has never been restored on a real phone.

**The privacy policy is now false.** `app/lib/screens/privacy_screen.dart`, the
README ("Customer data never leaves the device") and `docs/reference/privacy.html`
still say the book stays on the device. Fix this before any public push. It also
blocks the customer app (see 2.4).

### 2.3 Desktop web build of the agent app

The same Flutter codebase has a desktop target (`app/web/`, `kIsWeb` branches).

- `app/lib/shell.dart` has a permanent navigation rail (208 px) and a content
  column capped at 1080 px.
- New desktop-only widgets: `desktop_table.dart`, `auth_pane.dart` (sign-in as a
  centred card) and `profile_view.dart`.
- `sqlite3.wasm` and `sqflite_sw.js` are in `app/web/`, so the web DB runs in
  the browser. Whether it syncs against the cloud book end to end is untested
  from what I can see.
- `app/integration_test/agent_book_files_test.dart` is new, with portal-mock
  integration tests.

I found no deploy config or doc for hosting the web build.

### 2.4 "Customer web dashboard": not built

`customer-app/README.md` says **nothing is written**. It records two blockers:

1. The privacy policy is false (see 2.2).
2. **A customer has no identity in the system.** Everything is scoped by the
   agent's `account_id`. There is no per-customer row, no auth and no way to
   prove which RD account is theirs. This is a schema and auth design job
   before it is a UI job.

If a customer web dashboard was started somewhere else (another repo, branch,
Figma), it is not here. Check `git branch -a` and your other folders.

### 2.5 App work, 15–25 Aug (`1.0.0+27` → `+51`)

Mostly about making portal sync reliable and saving the agent time:

- **Sync fixes.**
  - The walk was cancelling its own navigations. Hop timeouts are now 25 s per
    click and 75 s per walk, based on measured portal latency (~17 s for
    Enquire).
  - "Nothing to click" is no longer treated as "nowhere to go".
  - Login no longer double-submits.
  - Matured accounts stay in the book.
  - A short-code fix.
- **Lists.**
  - Auto-pack into ₹20,000 lots (`lot_packing.dart`, `auto_list_screen.dart`),
    with a cap of 9 accounts and row colours for how late each is.
  - `lot_report.dart` prints the list with rebate and default fee.
  - There is a prompt to fetch missing ASLAAS numbers before saving
    (`aslaas_report_parser.dart`).
- **Other app work.**
  - Khata: a customer's payment calendar that the agent can write into.
  - Dark mode and a three-tone palette.
  - Screenshots are admin-controlled (off by default); the sync screen is always
    `FLAG_SECURE`.
  - The agent id is bound to what the portal states, not what was typed.
- **Version drift.** `pubspec.yaml` says `1.0.0+48`, but
  `SupabaseConfig.buildVersion` in `app/lib/services/supabase_config.dart` says
  `1.0.0+69`. The `buildVersion` constant is the patch marker (`HANDOFF.md`).
  The Shorebird release baseline (`HANDOFF.md`: `1.0.0+31`; the patch command
  needs the current one) has moved since, so check `shorebird releases list`.

### 2.6 Admin dashboard work

- Rebuilt flat and three-tone, with isometric charts and loading skeletons.
- Pages in `admin/app/(dash)/`: Overview, Activity, Assistant (the dashboard's
  own analytics agent: Groq tool-calling plus Synap memory), **Chat** (new,
  last commit: telemetry on the agents' in-app assistant), Board, Config,
  Devices/Users, Errors, Keys, OTP, Payments, Plans, Regions, Releases.
- Auth is much stronger than the original shared password.
  - Login needs the admin ID plus a **WhatsApp OTP**.
  - Sessions are revocable and last 7 days (`sessionEpoch.ts`).
  - One gate covers every route: origin check, rate limit, headers (`guard.ts`).
  - Admin OTPs are counted in the MSG91 cost view, since they are billable.
- It is Next.js 14 on Vercel. The service-role key is server-side only.

---

## 3. Architecture in one picture

```
Android app (Flutter) ──┐                       ┌── Admin dashboard (Next.js, Vercel)
Desktop web (Flutter) ──┤                       │     service_role, server-side only
                        ▼                       ▼
        Supabase edge functions: otp · sync · ingest · pay · groq · razorpay-webhook
                        │
                        ▼
        Postgres (RLS on, no anon policies; edge fns use service_role)
          telemetry · accounts/device_sessions · payments · plans · app_config
          · app_keys · releases · regions · otp · book_* (new)

   Portal creds + DOP sessions: phone Keystore / WebView only. Never uploaded.
   Groq: via the `groq` edge fn (keys in app_keys), not in the APK.
   OTA: Shorebird patches. Payments: Razorpay. OTP: MSG91 (WhatsApp).
```

| Function | Job |
|---|---|
| `otp` | WhatsApp OTP, phone↔agent binding, max 2 devices, session tokens |
| `sync` | Two-way book sync (new) |
| `ingest` | Anonymous telemetry, with Play Integrity |
| `pay` / `razorpay-webhook` | Plans, orders, entitlement |
| `groq` | LLM proxy with key rotation |

---

## 4. Things to confirm are actually live

I cannot check any of these from the repo.

1. `schema_book.sql` has been run on Supabase. It must run after `schema.sql`
   and `schema_otp.sql`.
2. The `sync` function is deployed:
   `supabase functions deploy sync --project-ref ojorpmtptryldizogtkz --use-api`
   (run from `backend/`).
3. The other schema files were applied in dependency order.
   - `schema_devices_view.sql` must come after `schema`, `schema_accounts`,
     `schema_regions` and `schema_otp`. Its column order is load-bearing; it can
     only append.
   - Deploy order from `HANDOFF.md`: `ingest` → dashboard → `schema_one_name.sql`.
4. Vercel env vars match `admin/.env.local.example`. The one-to-one mapping of
   the OTP/admin-ID variables added after that file was written needs checking.
5. Whether `payments_enabled` is on. Self-serve purchase was disabled ("Trial
   only") pending per-agent pricing.

---

## 5. Open issues, ranked

1. **Commit the restructure** (2.1) and fix stale paths in docs.
2. **Privacy policy is false** (2.2). Update the in-app screen, `privacy.html`
   and the README together.
3. **Release signing / keystore** (`SECURITY_AUDIT` A2, `HANDOFF`). The upload
   keystore (`app/android/upload-keystore.jks`) and its password exist in only
   two places. Losing either means no build can install over an existing one,
   which wipes every phone's collections ledger.
4. **Rotate the Supabase `service_role` key** (`SECURITY_AUDIT` A3). It was in
   cleartext on disk.
5. **Play Integrity is dormant** (A6). Rate limiting is the only abuse control
   on the public functions.
6. **Khata backup has never been restored.** `HANDOFF.md` describes a safe
   non-destructive drill (pick the file, enter the password, read the entry
   count, cancel).
7. **Batch submit has no auto-retry.** Careful around live payment calls.
8. **`lots` has no `cycle_ym`**, so the Downloads view and the don't-list-twice
   guard both derive it. Stamp it at save time.
9. **Cloud book sync conflicts.** Since avoiding conflicts was the point of the
   move, this matters. There is no UI for them. Last-write-wins on
   `client_updated_at` is the whole policy, so a wrong clock on a phone could
   win. Decide whether that is acceptable.
10. **Customer identity model** (2.4), if the customer product is a goal.

---

## 6. How to work in the repo

Every Flutter and Shorebird command runs from `app/`. Supabase commands run
from `backend/`.

```bash
cd app     && flutter test                   # agent app
cd app     && flutter analyze
cd admin   && npm run dev                    # http://localhost:3939
cd admin   && npx tsc --noEmit               # type-check (see gotcha)
cd backend && supabase functions deploy <fn> --use-api
cd backend/supabase/tests && deno test       # edge function tests (mocked supabase)
```

Shorebird patch (`HANDOFF.md`): from `app/`,
`shorebird patch --platforms=android --release-version=<release> -- --dart-define-from-file=env.json --no-tree-shake-icons`

Gotchas that already wasted time:

- **`shorebird` exits 0 on failure.** Grep the output for `Published`.
- **`next build` may not run locally** if `node_modules` is broken. Fix with
  `rm -rf node_modules && npm install`. Vercel installs fresh.
- **x86_64 is excluded from the APK** (packaging excludes in
  `app/android/app/build.gradle.kts`). Without that the patch bundle is too big
  to download on a slow link.
- **Don't re-add early "navigation started?" bails** in the portal walk, and
  don't blame `keepSessionAlive()` (`SYNC_HANDOVER.md`, section 3).
- `env.json` (build-time secrets) is git-ignored. Copy from `app/env.json.example`.
- Rebate and default fee are blank on lists submitted before ~16 Aug. They were
  never captured and cannot be recovered.

---

## 7. Doc index

| Doc | Read it for |
|---|---|
| `docs/plans/HANDOFF.md` | Release/Shorebird state, gotchas (written 16 Aug; paths stale) |
| `docs/plans/SYNC_HANDOVER.md` | Portal sync root cause and what the app is (20–21 Aug) |
| `docs/audits/SYNC_LOGIN_AUDIT.md` | Sync/login audit. A second copy was deleted from the root in the staged changes |
| `docs/audits/SECURITY_AUDIT.md` | Findings A1–A12 with status |
| `docs/audits/PAYMENTS_AUDIT.md`, `UX_AUDIT.md` | Payments and UX audits |
| `docs/ops/RUNBOOK.md` | Order of steps to deploy schema and functions |
| `docs/ops/prod.md`, `production-scaling.md` | Play Store and scaling plan. Written before the sync pivot, so its "no shared DB" premise is now outdated |
| `docs/plans/OTP_INTEGRATION_PLAN.md` | OTP and device-binding design |
| `docs/plans/chat-agent.md` | The in-app assistant spec |
| `docs/reference/PORTAL_WORKFLOW.md` | Portal page flow and selectors |
| `docs/reference/RAZORPAY_SETUP.md`, `SECURITY_HARDENING.md` | Setup and hardening |
| `backend/schema/schema_book.sql` header | Why the book is in the cloud and what is excluded |
| `customer-app/README.md` | Why the customer app is blocked |
