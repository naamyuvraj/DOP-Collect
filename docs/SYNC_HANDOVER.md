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

## 3. What the captures settled

The captures asked for in `recon/live/` arrived, and they answer the open
questions. Read this section before section 2's file table — two of its
assumptions were wrong.

### The captures are misnamed

Trust each file's `REPORTTITLE`, not the slot it was saved in:

| File | What it actually is |
|---|---|
| `03_dashboard__after_login` | `RMDashboard` ✅ as labelled |
| `04_account_list__page_1` | **`AgentAccountHomePage`** — an empty screen. No table, no rows, no content |
| `05_account_list__page_2` | **`AgentRDAccountSummaryAll`, page 1 of 48** — the real list |

### The path to the list is TWO clicks, with an empty screen in the middle

```
RMDashboard  --#Accounts-->  AgentAccountHomePage  --Enquire-->  AgentRDAccountSummaryAll
```

The dashboard capture has `HREF_Accounts` and **no `Agent Enquire` anchor at
all** — the submenu is not in its DOM until Accounts is clicked. So the middle
screen is a necessary hop, and because it renders nothing the old walk could not
tell reaching it apart from a click that went nowhere. It kept re-clicking a
link it had already used.

### The live failure: the walk was cancelling its own navigations

**Confirmed 21 Aug 2026 against the live portal**, by attaching Chrome DevTools
to the app's WebView — `adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>`,
then `test/qa_repro/js/cdp_eval.js`. Timings, measured:

| Step | Real time |
|---|---|
| Dashboard → Accounts (`AgentAccountHomePage`) | ~3.5 s |
| **Accounts home → Enquire → the list** | **~17 s** |

`navigateToAccountList` allowed **11 s** per hop. It expired mid-navigation,
re-read the page (unchanged, because the response had not arrived), concluded
the portal had dropped the click, and clicked again — cancelling the load it had
been waiting for. Four clicks, each looking like it achieved nothing, then the
ceiling. That is the live trace exactly, and the portal's own message block was
**empty** throughout: it was never complaining, just answering slowly.

Two things kept this hidden:

- **`onPageFinished` is not "the page I asked for has arrived".** It fires at
  document load, before Finacle's deferred scripts build the left menu. The walk
  read `AgentAccountHomePage` at 23,393 chars where the finished page is 26,039
  — deciding on a DOM ~2,600 characters short.
- **The completer could already be resolved** by an earlier navigation, so the
  wait returned instantly and the caller read the page it was already on.

**The fix.** Fingerprint the page (URL + document size) before clicking, then
wait for it to *change and hold still*. Patience per click 25 s, walk budget
75 s, both sized from the table above.

There is deliberately **no** early "has a navigation started?" bail.
`readyState` was the obvious candidate and it is wrong here: these are form
posts, so the old document stays `complete` until the response begins arriving.
That bail gave up on healthy navigations at 3 s. Do not reintroduce it.

### The keep-alive was NOT the cause

An earlier pass of this document blamed `keepSessionAlive()`, and that is wrong.
The walk fails at the Enquire click, before any keep-alive runs. **Do not
re-derive that theory.**

The reasoning was plausible — the control really is
`<input type="Submit" name="Action.Action.Action.PREVENT_SESSION_TIMEOUT__">`,
so it navigates, and firing it mid-walk really would post on top of the walk —
and the `isDriving` guard added for it is worth keeping on those grounds. It is
verified from the portal's side: a pest calling it every 300 ms through a full
48-page walk produced **zero** posts. But it did not cause the reported failure,
and the "previous click was still being processed" banner in the capture came
from ordinary human double-clicking during the capture session, not from it.

### Suspect #1 from the old list is resolved; #2 and #3 are cleared

- **Session expiry mid-walk** — confirmed as the mechanism, but the cause was
  ours, not the clock. `#sessionTimeout` is `300` (five minutes) and
  `sessionAlertTime` is `60`; a page turn every few seconds stays well inside
  that. It was the keep-alive's stray post, not the timeout.
- **The page-position guard** is correct and stays. `Page 1 of 48` lives in
  `<span class="paginationtxt1">` and is read directly.
- **The empty-page guard** is correct and stays, but it was firing on healthy
  pages — see below.

### Stricter parsing was dropping a fifth of the book

The portal leaves **"Next RD Installment Due Date" blank** once an account
reaches its 60-month term. On the captured page that is **2 rows in 10**, both
at `Month Paid Upto = 60`. The parser counted an unparseable date as a corrupt
row and dropped it, so those accounts vanished from the book — and because a
`complete` sync closes everything it did not see, a full walk would then have
tried to close roughly a fifth of the agent's customers at once. The closure
ceiling (`max(10, 5%)`) would have refused the merge, so **sync would have
reported success and saved nothing**.

Blank now counts as `ParsedPage.matured`, kept apart from `rejected`, and is
reported to the agent in its own words.

### The list DOM is far better than column-position scraping

Every cell carries a stable per-field id:

```
HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY[i]   (an <a>)
HREF_CustomAgentRDAccountFG.ACCOUNT_NAME_ALL_ARRAY[i]     (a <span>)
HREF_CustomAgentRDAccountFG.DEPOSIT_AMOUNT_ALL_ARRAY[i]
HREF_CustomAgentRDAccountFG.MONTH_PAID_UPTO_ALL_ARRAY[i]
HREF_CustomAgentRDAccountFG.NEXT_RD_INSTALLMENT_DATE_ALL_ARRAY[i]
```

The parser now reads those first and falls back to the header-driven table walk
only if they are gone.

The listing also advertises its own size — `Displaying 1 - 10 of  480 results`
(note the double space) — which is an independent check on the walk: 48 pages ×
10 rows should be 480, and the sync now refuses to call itself `complete` if the
two disagree.

### Other facts worth having

- **Pagination is form posts, not links**: `Action.AgentRDActSummaryAllListing.GOTO_NEXT__`
  / `GOTO_PREV__` / `GOTO_PAGE__`, with the page box named
  `CustomAgentRDAccountFG.AgentRDActSummaryAllListing_REQUESTED_PAGE_NUMBER`.
  They are `type="Submit"` with a **capital S**, and CSS attribute matching is
  case-sensitive for `type` — `input[type="submit"]` matches none of them.
  Never filter on it.
- **The login page fields** are `AuthenticationFG.USER_PRINCIPAL`,
  `AuthenticationFG.ACCESS_CODE` and `AuthenticationFG.VERIFICATION_CODE` (the
  captcha answer). The captcha image is `#IMAGECAPTCHA`; `#TEXTIMAGE` refreshes
  it. The old write-back selector `[id*="captcha" i]` matches **nothing** on
  this page.
- **The virtual keypad question is answered.** `settingPinPadCtl(…)` calls
  `disbleTextField('AuthenticationFG.ACCESS_CODE','true')` and writes into a
  readonly `#input_buffer`. So if the agent has ever opened the keypad, the real
  password field is left readonly and assigning `.value` silently does nothing —
  check that before blaming the Keystore for an empty password.
- **`02_login__after_submit_failed` is not a failed submit.** It is byte-identical
  to `01` apart from the clock, so there is still no capture of the portal's
  login-error markup. `07_whatever_screen_failed` is still the placeholder.
- **The captures are desktop-browser ones** (`capture.js`, Chrome on macOS).
  The app sends a desktop UA, so the markup should match, but nothing here has
  been confirmed against the WebView on the handset.

## 4. What was changed

- `lib/data/portal/portal_dom.dart` (**new**) — every selector, marker and
  regex, pinned to the captures, with the screen graph documented. Exact
  selectors first, the old loose ones kept as fallbacks.
- **The keep-alive no longer collides.** `keepSessionAlive()` refuses while
  anything owns the page (`PortalSyncEngine.isDriving`), and the timer in
  `SyncScreen` additionally skips while `_busy`. When it does fire it now waits
  out the navigation it starts.
- **The walk classifies the screen before it clicks.** On the dashboard only
  Accounts is attempted; the Enquire link is only reached for once it can exist.
  Clicks are capped at four for the whole walk with a doubling gap that is
  clamped to the caller's deadline. Measured on the dropped-click case:
  **20 clicks → 4**.
- **Navigation failures are typed** (`NavFailure`), so a spent session says
  *"The portal ended this session. Log in again"* instead of advice that cannot
  work.
- **The double-post banner is understood.** It means "you are going too fast",
  and the page underneath is the right one, so the engine backs off and re-reads
  instead of clicking again.
- **`_gotoPage` no-ops** when the portal already says it is on that page — the
  rewind to page 1 used to post on top of the navigation that had just landed.
- **`_clickLinkByText` resolves downward** (`querySelector('a')`) before walking
  up, and only reports a click when it landed on a real control — it used to
  click the wrapping `<td>` and report success (J2).
- **Blank due dates are maturities, not parse failures**, counted separately and
  surfaced to the agent.
- **A completed walk is cross-checked** against the portal's own
  "Displaying … of N results" before it may call itself `complete`.

### Tests

- `test/portal_live_capture_test.dart` (**new**, 14 tests) — runs the classifier
  and parser against the real captures. Skips itself when `recon/live/` is
  absent, and asserts only on shape and counts, never on a live value.
- `test/qa_repro/nav_engine_defects_test.dart` — rewritten. N1 and N2 now assert
  the fix rather than document the fault, plus the two-hop path, the empty
  middle screen, the busy banner, and that keep-alive refuses to fire mid-walk.
- `test/qa_repro/fake_webview.dart` — the scripted portal now matches the real
  screen graph. Its `dashboardHtml` used to carry the Enquire link, which
  encoded the belief that the list was one click from login.
- **`tool/mock_portal.py` (new) — the captures, replayed as a navigable
  portal.** This is the piece that closes the loop the handover kept asking
  about: the defects are all navigation timing, and timing does not reproduce
  against a string of HTML. It serves `recon/live/` over HTTP with the link
  targets rewritten, so a **real Android WebView** can be walked from the login
  page to page 48 — no live banking session, no spent login attempt. Faults are
  armable (`expire`, `busy`, `drop`) and it counts what each control actually
  received. See `tool/README.md` for what it is and is not faithful about.
- **`integration_test/portal_sync_mock_test.dart` (new)** — drives the engine
  against it on a device. The keep-alive test is the important one: it hammers
  `keepSessionAlive()` every 300 ms through a full walk and asserts the
  **portal's own** counter stays at zero. The engine believing it declined is
  not evidence; the portal never receiving the post is.

### Still open

- **C3** — the 900 ms captcha timer still races the Keystore read. Untouched
  here.
- **J1** — the captcha fill still fires no `keydown`/`keypress` and never
  focuses. The capture does not settle whether this portal needs them.
- **J3** — the captcha OCR still runs on every page of the walk.
- **A1** — auto-start still probes `isAuthenticated()` once with no settle.
- Nothing in this pass has been run against the live portal or on a handset.
  The mock harness proves the walk's mechanics; it cannot prove what Finacle
  does with a replayed token, which is the one thing only the real portal can
  settle.

### Seeing what the walk is doing

`PortalSyncEngine.trace` narrates every decision with timings — screen
classification, each click and whether it landed, per-page counts, and every
keep-alive that was declined. It is a **static** field on purpose: a hot reload
can redirect it without rebuilding the screen that owns the engine, which is the
difference between watching a live portal session and having to start one over.
Silent in release.

Note that the sync screen forces `FLAG_SECURE`, so `adb screencap` and
`uiautomator dump` both come back empty on it. That is working as designed — it
is a live banking login — but it does mean the log is the only window in.

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
