# DOP Collect — the sync problem, and what the app is

Written 20 Aug 2026, at release `1.0.0+44` + patch 2 (`+46`). Sync still fails.
This is everything needed to pick the problem up cold.

---

## 1. What the app is for

A DOP (India Post) RD **collection agent** carries a book of recurring-deposit
customers. Every month he visits them, takes cash, and files it with the post
office in **₹20,000 lists**. The paperwork is the job; the app exists to stop
the paperwork eating the round.

The agent it is built for is one man in his late fifties working from a phone in
daylight. That constraint shows up all over the codebase — contrast ratios
chosen for sunlight, thumb-sized targets, wording that says what to *do* rather
than what went wrong.

What it does:

- **Holds the book offline.** SQLCipher-encrypted on the phone. It never leaves.
- **Runs the collect round.** Who to visit, how much each owes today, cash count
  at day end.
- **Keeps a khata per customer** — a calendar of every handover, which the agent
  can also write into directly.
- **Builds and files the ₹20,000 lists**, and submits them on the portal.
- **Answers questions** in Hindi or English, on-device or via Groq.

There is an admin dashboard (Next.js + Supabase) for the fleet: agents, devices,
OTP logins, errors, remote config flags.

## 2. Why there is scraping at all

**The DOP agent portal has no API and no export.** It is a Finacle deployment at
`dopagent.indiapost.gov.in`, rendered server-side, driven by form posts and
transaction tokens. The only way to get the agent's own book out of it is to log
in as him and read the rendered table.

So the app drives a **real WebView**: it loads the portal, autofills his
credentials (from the Android Keystore) and the captcha (on-device ML Kit OCR),
clicks through to *Accounts → Agent Enquire & Update Screen*, and parses the
account table page by page — typically ~47 pages.

Two consequences worth internalising:

- **It is his live banking session.** The password is real. This is why the sync
  WebView forces `FLAG_SECURE` on regardless of the screenshot setting, and why
  a retry loop that re-clicks aggressively is dangerous: Finacle treats replayed
  transaction tokens as an attack.
- **Everything is timing.** There is no "request finished" signal, only page
  loads and DOM state. Nearly every sync bug in this file's history has been a
  race, not a parsing error.

### The moving parts

| File | Job |
|---|---|
| `lib/screens/portal/sync_screen.dart` | The WebView, login autofill, captcha OCR, the visible sync UI |
| `lib/data/portal/portal_sync.dart` | `PortalSyncEngine` — the walk: navigate, paginate, read HTML |
| `lib/data/portal/agent_list_parser.dart` | Turns the rendered table into `RdAccount`s |
| `recon/` | Real captured portal HTML + a selector map (`PORTAL_WORKFLOW.md`) |

---

## 3. The current failure

**Symptom now:** sync reaches the account list, then reports
**"Session expired — please log in again."**

**Symptom before patch 2:** *"Could not open the account list"* — while the list
was visibly open on screen behind the message.

### What has been fixed

- **The give-up condition** (patch 2, `+46`). `navigateToAccountList` gave up the
  moment neither the Enquire link nor the Accounts menu could be clicked. But
  the Enquire link leaves the DOM the instant its navigation starts — so
  "nothing to click" usually means "the click landed and the page is coming".
  It now waits out an in-flight load before declaring failure. This is what
  produced the message-and-list-together symptom.

### What has been ruled out — do not re-investigate

- **Frames.** The portal is *not* frameset-based. The real capture in
  `recon/portal_01_list_select.html` has zero `<frame>`/`<iframe>` tags, so
  reading `document.documentElement.outerHTML` is sufficient.
- **The readiness predicate.** `_hasAccountTable` wants `"Account No"` **and**
  `Page N of M`. The real capture has `Account No` and `Page 1 of 47`. It works.
- **A session-expiry false positive.** `_isSessionExpired` matches the exact
  strings `Session is Expired` / `Session Expired`. The healthy page only
  contains `Prevent Session Timeout` and `session will timeout in`, neither of
  which matches. So when it fires, the portal probably *has* expired.

### Live suspects, in order

1. **The session genuinely expiring mid-walk.** The portal warns
   *"Your session will timeout in 0 hrs: 5 mins"*. A 47-page walk at a 60s page
   timeout can outrun that. There is a `_keepAliveTimer` firing
   `keepSessionAlive()` every 2 minutes — **verify it actually does something on
   the current portal**; if the keep-alive control moved or was renamed, the
   session dies on schedule and everything downstream is a symptom.
2. **The page-position guard** (added by the QA/data pass, in `+44`, new):
   ```
   if (shown != 0 && shown != page) → abort
     "Sync lost its place at page N of M (the portal is showing page X)"
   ```
   Reads the portal's own page number right after clicking Next. If the DOM
   lags the click, this aborts a healthy sync.
3. **The empty-page guard** (same pass, new):
   ```
   if (parsed.accounts.isEmpty && parsed.rejected == 0) → abort
     "Page N of M came back empty — the portal did not finish loading it"
   ```
   Aborts instead of waiting when a table has rendered but its rows have not.
4. **Stricter parsing.** Rows whose due date will not parse or whose
   denomination reads as zero are now **dropped and counted** rather than given
   sentinel values. Correct in principle — the old `DateTime(2000)` sentinel put
   accounts ~320 months overdue and inflated To Collect by lakhs — but a matured
   or fully-paid account with a blank due date now vanishes silently.
   `ParsedPage.rejected` is computed and **never shown anywhere**. Surfacing it
   is worth doing regardless of this bug.

### The diagnostic gap that has cost the most

Until today there was **no way to get the failing page off the phone**. Every
step of this has been inference from a symptom. The `</>` button in the sync app
bar now writes a named file and opens the share sheet — see `recon/live/README.md`.

**The two captures that would end this: `04_account_list__page_1` and
`06_session_expired__as_seen`.**

---

## 4. Known defects, documented and unfixed

Skipped repro tests under `test/qa_repro/` — each un-skips when fixed.

- **N1 — click storm.** When the portal silently drops a click, the walk
  re-clicks on every slice of every hop: ~20 clicks, no backoff, no cap.
  Finacle reads replayed tokens as an attack. **A fix was attempted and
  reverted**: capping clicks charged failed *lookups* as clicks (the Enquire
  link is often absent until the Accounts menu opens), and it made the
  guard-page case hang for the full timeout instead of giving up. Do not repeat
  that approach without a way to test against the real portal.
- **C3 — captcha timer races the Keystore read.** `Credentials.load()` is a
  two-hop platform round trip, not a cache, and a fresh one is needed on the
  first page-finish. Evidence only, no acceptance test.

Fixed this session and worth knowing about: **C1** (the daily auto-login counter
charged *successes*, so four good logins in a day blocked the fifth screen —
it guards Finacle's ten-*failed*-attempt lockout, so a success now clears the
day) and **C2** (a Keystore fault threw into a future awaited unawaited, killing
autofill silently for the life of the screen; it now degrades to empty
credentials and reports via Analytics).

---

## 5. Release state

- **Release `1.0.0+44`**, patches 1 and 2 applied → installs report `1.0.0+46`.
- Branch **`removation`**, **not pushed**. It carries this session's work plus
  two other agents' work that exists in no other place.
- Rule for shipping: **native code or Android resources changed → release;
  Dart only → patch.**

### Manual steps, already done

- `admin/schema_management.sql` run (adds `admin_session_epoch`).
- `supabase functions deploy ingest --use-api`.
- Dashboard deployed.
