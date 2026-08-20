# DOP Collect — Sync Login Audit & Re-verification

**Date:** 20 August 2026 · branch `removation` · verified at `e403641` (1.0.0+44) · Flutter 3.44.6
**Scope:** the portal sync login flow end to end — [sync_screen.dart](lib/screens/portal/sync_screen.dart), [portal_sync.dart](lib/data/portal/portal_sync.dart), [credentials.dart](lib/data/credentials.dart), [captcha_solver.dart](lib/data/portal/captcha_solver.dart), and the daily-login counter in [app_settings.dart](lib/data/app_settings.dart).
**Triggered by:** three field reports — the captcha fills but Login is never pressed; the password is sometimes never typed; login succeeds but Accounts never opens.
**At `e403641`:** `flutter test test/qa_repro/` **11/11 green** · DOM suite **8/8** · `flutter analyze` clean.

Nine defects were found. Three were fixed in [`1cf4e3e`](#fixed) and are **re-verified fixed here**. Six remain open.

---

## ⚠️ Read before you commit

**The working tree has the N1 fix backed out, and the backout is staged.**

`navigateToAccountList` in the working copy of [portal_sync.dart](lib/data/portal/portal_sync.dart) is the pre-`1cf4e3e` version — no click ceiling, no backoff. The index and the working tree agree, so **committing as things stand ships 1.0.0+44's fix reverted.**

| Tree | N1 acceptance test | Clicks on a dropped-click |
|---|---|---|
| `e403641` (HEAD) | passes | **4** in 8.9 s |
| working tree | **fails** | **20** in 5.6 s |

Verified by running `test/qa_repro/` in a throwaway worktree at HEAD versus in place. `test/qa_repro/nav_engine_defects_test.dart` is reverted to its pre-fix form too, so the two are consistent with each other — this looks like a stale checkout or an editor undo rather than a deliberate rework. Restore with `git checkout e403641 -- lib/data/portal/portal_sync.dart test/qa_repro/nav_engine_defects_test.dart` if that's what happened.

---

## Status

Defect IDs match the test group names in [test/qa_repro/](test/qa_repro/) — those are authoritative.

| ID | Defect | Severity | Status at `e403641` |
|---|---|---|---|
| [C1](#c1) | The daily auto-login budget is spent by *successful* logins and never reset | 🔴 CRITICAL | ✅ **Fixed** — re-verified |
| [C2](#c2) | A Keystore fault kills autofill for the whole screen, silently | 🟠 HIGH | ✅ **Fixed** — re-verified |
| [N1](#n1) | One dropped click becomes 20 clicks in 5.6 s | 🟠 HIGH | ✅ **Fixed** — re-verified (⚠️ reverted in working tree) |
| [C3](#c3) | The 900 ms captcha timer races the Keystore read; auto-submit then abandoned permanently | 🔴 CRITICAL | ❌ **Open** |
| [J1](#j1) | The captcha fill fires no key events and never focuses the field | 🟠 HIGH | ❌ **Open** |
| [J2](#j2) | The Enquire-link fallback clicks the wrapping `<td>`, then reports success | 🟠 HIGH | ❌ **Open** |
| [A1](#a1) | Auto-start probes once, with no settle and no retry | 🟠 HIGH | ❌ **Open** (📖 unproven) |
| [N2](#n2) | A spent session is misdiagnosed as a missing link; the remedy shown cannot work | 🟡 MEDIUM | ❌ **Open** |
| [J3](#j3) | The captcha OCR runs on every page of the walk | 🟡 MEDIUM | ❌ **Open** |

**[C3](#c3) is the one to take next.** It is the remaining CRITICAL, it is the direct cause of "fills the captcha but I still have to tap Login" on cold starts, and it was not in `1cf4e3e`'s scope — the 900 ms timer and the surrender-without-retry gate are both still exactly as they were.

**Provenance.** ✅ MEASURED means a test in `test/qa_repro/` executes the shipping code and the numbers quoted are its output. 📖 INFERRED means code reading only, never executed — [A1](#a1) is the only one.

---

## Symptom → cause

More than one cause per symptom is why it reads as random. Struck-through causes are fixed.

| Reported as | Caused by | Pattern to expect |
|---|---|---|
| "Fills the captcha but gets stuck there, I have to tap Login" | ~~C1~~, **[C3](#c3)**, **[J1](#j1)** | C1 was deterministic from the fifth portal screen of the day — now fixed. C3 hits cold starts and clears on a warm one. J1, if real, is constant. |
| "Sometimes forgets to fill the password" | **[C3](#c3)**, ~~C2~~ | C3 fills it a moment too late — it does appear, just after the decision was taken. C2 never filled it and never recovered until reinstall; now fixed. |
| "Gets logged in but cannot open Accounts" | ~~N1~~, **[J2](#j2)**, **[A1](#a1)**, **[N2](#n2)** | A1 shows as a screen that does nothing at all. J2 still reports a false success; N1's retry loop no longer amplifies it. |

---

<a id="fixed"></a>
## Fixed and re-verified

Commit [`1cf4e3e`](#) *"Portal login: fix the three defects QA left skipped"*. All three acceptance tests are now un-skipped and green at `e403641`.

<a id="c1"></a>
### C1 — daily auto-login budget · 🔴 CRITICAL · ✅ FIXED

**Was:** the gate `_loginClicks < 4 && dailyAttempts < 4` drew down a counter that incremented the moment the Log in button was clicked, succeeded or failed, with no reset anywhere. Four ordinary portal trips — Sync, Prepare, Submit, Deep Sync — exhausted the day on four *successful* logins, and every screen after that showed *"daily auto-login limit reached. Tap Login."* The counter guards Finacle's ten-**failed**-attempt lockout, which a success clears on the portal side; successes were the one thing that should never have drawn it down.

**Now:** the click sets `_autoLoginPending`, and `_resolveAutoLoginOutcome()` decides on the next page-finish — still on the login page means rejected, so charge it; anywhere else means success, so `resetDailyAutoLoginCount()`. A failed DOM read charges the attempt, which is the right way round: over-counting costs one auto-login, under-counting costs the agent his portal account.

**Verified:** `a successful login must not consume the day's budget` — green.

<a id="c2"></a>
### C2 — Keystore fault kills autofill silently · 🟠 HIGH · ✅ FIXED

**Was:** `Credentials.load()` did not catch. `flutter_secure_storage` throws `PlatformException` on Android when a Keystore entry cannot be decrypted — a known failure after an app update or device restore. `_credsReady` became an errored future, and because `_autofillIfLogin()` is fired *unawaited*, the `await` rethrew into nothing. Neither field was ever typed again on that screen, and the agent was told nothing.

**Now:** `load()` catches and degrades to empty credentials.

**Verified:** `load() degrades to empty credentials instead of throwing` — green.

<a id="n1"></a>
### N1 — dropped click became a click storm · 🟠 HIGH · ✅ FIXED (⚠️ see warning above)

**Was:** a four-hop outer loop wrapping a four-slice inner loop, every slice re-clicking the Enquire link. Measured: **20 clicks in 5.64 s**, no backoff, no cap. Page-finish fires even when the DOM never changes, so `_awaitLoad` returned immediately and the 11 s slice never applied — the whole budget went out as rapid-fire clicks on one Finacle link. That is the traffic shape that trips the stale-transaction-token guard, making this a plausible *cause* of the poisoned sessions in [N2](#n2) rather than only a victim.

**Now:** a hard ceiling of `_maxNavClicks = 4` for the whole walk with a doubling gap. The time budget is unchanged — it is spent waiting instead of clicking.

**Verified at `e403641`:** `totalClicks=4 elapsed=8926ms`, acceptance test green.

---

## Open

<a id="c3"></a>
### C3 — The captcha timer races the Keystore read, and losing forfeits auto-submit for good
**🔴 CRITICAL · ✅ MEASURED · OPEN**

**Where:** [sync_screen.dart:132](lib/screens/portal/sync_screen.dart#L132) (the 900 ms timer) · [sync_screen.dart:140](lib/screens/portal/sync_screen.dart#L140) (`_credsReady`) · the credential gate that surrenders, ~[:445-456](lib/screens/portal/sync_screen.dart#L445-L456)

One page-finish starts two independent things: `_autofillIfLogin()`, which awaits `_credsReady`, and a **fixed 900 ms timer** that starts the captcha solve. `Credentials.load()` is a SharedPreferences load, a plaintext-migration pass, and two Android Keystore reads. The first Keystore touch on a cold start routinely costs several hundred milliseconds and can exceed a second on a mid-range handset.

When the timer wins, the captcha is read and filled correctly, the credential gate reads the DOM, finds the fields still empty, snacks *"add your Agent ID and password"* and returns. **That return schedules no retry.** The credentials land half a second later and nothing re-examines the situation — the screen sits with a valid captcha waiting for a human tap.

`_credsReady` is built once, in `initState`, so the only page load that can lose this race is the first — which is always the login page. Cold start loses, warm start wins. That is the whole of the "sometimes".

```
test/qa_repro/login_autofill_defects_test.dart
  EVIDENCE C3: 2 Keystore reads per load()                 PASS
    (plus a prefs load and a migration pass, against a
     fixed 900ms timer armed on the same callback)

test/qa_repro/js/dom_repro.js
  C3-1  credsFilled returns "false" while the Keystore
        read is still in flight                            PASS
     → empty fields → gate says false
     → _autofillCaptcha returns with NO retry scheduled
```

**Fix.** Gate the captcha solve on `await _credsReady` rather than a wall-clock delay, so the ordering is guaranteed instead of hoped for. And make the credential gate re-arm rather than surrender: if the fields are empty, wait for `_credsReady`, re-check once, and only then hand off to the user.

---

<a id="j1"></a>
### J1 — The captcha fill fires no key events and never focuses the field
**🟠 HIGH · ✅ MEASURED (conditional) · OPEN**

**Where:** [sync_screen.dart:247-258](lib/screens/portal/sync_screen.dart#L247-L258)

`_fillCaptchaJs` assigns `.value` and dispatches exactly `input`, `change`, `keyup`, `blur`. It never calls `focus()` and never dispatches `keydown` or `keypress`.

Finacle login pages of this vintage commonly enable the Log in button from a `keypress` handler, often on a field that must be focused. Against such a page the button stays disabled through all ten of the 500 ms polls, and the flow falls through to *"tap Login"* with a perfectly good captcha in the box.

**Conditional.** This proves our side is fragile; it does **not** prove the DOP page gates on `keypress`. See [Not tested](#not-tested).

```
test/qa_repro/js/dom_repro.js   (runs the real extracted script)
  J1-1  no keydown/keypress, never focuses                 PASS
     → dispatched [input, change, keyup, blur]
  J1-2  a portal that enables Login on keypress stays
        disabled after our fill                            PASS
     → _loginJs returns "false" for all 10 polls
```

**Fix.** Focus the field, then dispatch `keydown` and `keypress` alongside the existing four. It costs nothing against a page that does not need them.

---

<a id="j2"></a>
### J2 — The Enquire-link fallback clicks the wrapping cell and reports success
**🟠 HIGH · ✅ MEASURED (conditional) · OPEN**

**Where:** [portal_sync.dart](lib/data/portal/portal_sync.dart) · `_clickLinkByText`

It searches `a, input, button, span, td` by substring and clicks `els[i].closest('a') || els[i]`. Two facts collide: in document order an ancestor precedes its descendant, so a `<td>` containing the link is always examined **before** the link itself; and `closest()` walks **up**, so from that `<td>` it never finds the anchor inside it.

The result is a click on the table cell — which navigates nowhere — and a return of `'true'`, so the caller believes it moved. N1's fix bounds how much that false success costs, but does not stop it being wrong.

The fast path is fine: when the anchor carries `name` or `id` containing *Enquire*, `_clickSelector` handles it correctly and this never runs. The defect only bites when it does not — which needs a DOM capture to confirm.

```
test/qa_repro/js/dom_repro.js
  J2-1  the <td> is clicked, the link is not               PASS
     → script returns "true", anchor never fired
  J2-2  same DOM WITH name*="Enquire" works                PASS
  J2-3  document order proves it                           PASS
     → querySelectorAll order = [cell, link]
     → td.closest('a') === null
```

**Fix.** Resolve downward as well as upward — `el.querySelector('a')` before falling back to `closest('a')` — and skip container elements that have a clickable descendant. Better still, return `'false'` unless the thing clicked was an anchor or a button, so a non-navigating click stops masquerading as a successful one.

---

<a id="a1"></a>
### A1 — Auto-start probes once, with no settle and no retry
**🟠 HIGH · 📖 INFERRED — not reproduced · OPEN**

**Where:** [sync_screen.dart](lib/screens/portal/sync_screen.dart) · `_maybeAutoStart` · [portal_sync.dart](lib/data/portal/portal_sync.dart) · `isAuthenticated`

`_maybeAutoStart()` runs straight off the page-finish callback and calls `isAuthenticated()` exactly once, with no settle delay — unlike every other DOM read in the engine, which calls `_settle()` first. The probe looks for `#Accounts` / `a[name="HREF_Accounts"]`.

`onPageFinished` fires at document load. If the dashboard menu is written by a deferred script or an XHR — ordinary for this portal — the probe returns false. The post-login dashboard is the last navigation of the session, so `onPageFinished` never fires again and **nothing retries**. The screen sits on a perfectly good logged-in dashboard doing nothing.

**Not reproduced.** Exercising it needs a widget test of `SyncScreen`, which pulls in the SQLCipher-backed `AccountRepository` and a `WebViewWidget` platform — out of scope for this pass. Rated High on reasoning, and it is the finding most worth confirming on a handset before spending effort on it.

**Fix.** Poll `isAuthenticated()` for a few seconds after page-finish instead of probing once, and settle before the first read.

---

<a id="n2"></a>
### N2 — A spent session is misdiagnosed as a missing link, and the remedy shown cannot work
**🟡 MEDIUM · ✅ MEASURED · OPEN**

**Where:** [portal_sync.dart](lib/data/portal/portal_sync.dart) · `navigateToAccountList` (no blocked-page probe) · `_isBlockedPage` (the probe that exists)

`_isBlockedPage()` detects Finacle's stale-token guard — *"close this window and try accessing the application in a new browser window"*. It is called from three places in the file, and `navigateToAccountList` is not one of them.

So when a session is poisoned, navigation returns a bare `false`, indistinguishable from "the link was not found", and `_sync()` renders that as *"Open Accounts → Agent Inquire and Update, then tap Sync."* — advice that cannot work, because only a fresh login clears a spent token. The agent follows it, fails, and repeats.

```
test/qa_repro/nav_engine_defects_test.dart
  EVIDENCE N2: 9 scripts injected, 5 DOM reads,
               enquireClicks=1                             PASS
```

**Fix.** Probe `_isBlockedPage()` inside the navigation loop and return a typed reason rather than a bare boolean, so the screen can say *"the portal ended this session — log in again"*. This needs a small API change, which is why it carries no compiled acceptance test.

---

<a id="j3"></a>
### J3 — The captcha OCR runs on every page of the sync, not just the login page
**🟡 MEDIUM · ✅ MEASURED · OPEN**

**Where:** [sync_screen.dart:132](lib/screens/portal/sync_screen.dart#L132) (fires on every page-finish) · the image scorer, `_captchaExtractJs`

`_autofillCaptcha` has no "am I on the login page?" gate. During a 47-page walk it runs on every page-finish, and the scorer only needs a score of 3 to accept an image. A plain 120×22 header or spacer GIF scores **4** — 3 for captcha-like dimensions, 1 for being wide.

Each accepted image is upscaled and binarised into three canvases and put through three ML Kit OCR passes. On the low-end handsets where pages already stall, that is CPU spent competing with the page walk on every single page.

The write-back selector is loose too: `[id*="captcha" i]` matches any input whose id merely contains the substring, so a junk read can be written into an unrelated field.

```
test/qa_repro/js/dom_repro.js
  J3-1  a 120x22 spacer gif on a NON-login page scores
        high enough to be OCR'd                            PASS
     → dbg="1 imgs; top 120x22 s4; used 120x22 x3"
     → 3 canvases, 3 ML Kit passes, on a header gif
  J3-2  the junk read is written into any input
        matching [id*=captcha]                             PASS
```

**Fix.** Run the solver only when the login fields are present. Tighten the write-back selector to the portal's actual captcha field, and require a keyword hint — not size alone — before an image is accepted for OCR.

---

## What testing changed about the first read

Two claims from the initial code audit did not survive measurement. Recorded so nobody works from the earlier version.

- **The guard page is not thrashed.** The first read said the engine keeps clicking a dead session. Measured: exactly **one** Enquire click, because the guard page has no Enquire link to find. The real defect there is misdiagnosis ([N2](#n2)), not thrash — and the thrash lived on the dropped-click path instead ([N1](#n1)), where it was arguably what *created* the guard page.
- **"About three minutes of nothing" applied to one path only.** It held when page-finish never fired (4 × 4 × 11 s ≈ 2 min 56 s). When page-finish did fire, the identical loop burned all 20 clicks in 5.6 s — far worse for the portal, far shorter for the user.

---

<a id="not-tested"></a>
## Not tested

The boundary of this pass. Two findings depend on facts only a handset can settle.

- **No live portal, no handset.** Nothing here touched the real DOP portal; there are no agent credentials in this environment and a live banking login is not something to automate for a test run. Every DOM reproduction uses the app's real injected scripts against a constructed page.
- **The real login DOM is unverified.** [J1](#j1) and [J2](#j2) are conditional: they prove the app fails *if* the page gates the button on `keypress`, and *if* the Enquire anchor lacks a matching `name`/`id`. The app already ships the tool to settle both — the **Copy HTML** debug button on the sync screen. Capture the login page and the post-login dashboard and both become yes-or-no.
- **[A1](#a1) is unproven.** Reasoned from the code, not executed.
- **Timing figures are desktop-measured.** The 8.9 s in the fixed [N1](#n1) comes from a fake portal that answers instantly; a real handset will differ. The *click count* of 4 is structural and will not.
- **The C1 fix is not confirmed against a real rejected login.** `_resolveAutoLoginOutcome` decides success by whether the login fields are still on screen; that is the right signal, but it has only been exercised against a constructed page.
- **Not investigated:** whether the portal's virtual keypad reads the password field through a hidden mirror input, which would be a separate cause of a rejected login. Worth a look while the DOM capture is open.

---

## Suggested order for what's left

| Step | Defects | Why here | Size |
|---|---|---|---|
| 0 | ⚠️ working tree | Restore the N1 fix before anything else, or it ships reverted. | XS |
| 1 | [C3](#c3) | The remaining CRITICAL, and the live cause of "I still have to tap Login" on cold starts. | S–M |
| 2 | *DOM capture* | Settles [J1](#j1) and [J2](#j2) before either is coded against. Use the app's Copy HTML button. | XS |
| 3 | [J1](#j1), [J2](#j2) | Cheap and low-risk once the capture confirms them. | S |
| 4 | [N2](#n2) | Give navigation a typed failure reason so a spent session stops being reported as a missing link. | S |
| 5 | [A1](#a1), [J3](#j3) | A1 after it is confirmed on a handset. J3 is a gate and a tighter selector. | S |

---

## Test assets

Committed under [test/qa_repro/](test/qa_repro/) as of `1cf4e3e`.

| File | What it does |
|---|---|
| [login_autofill_defects_test.dart](test/qa_repro/login_autofill_defects_test.dart) | C1, C2, C3 against the real `AppSettings` and `Credentials`, with a Keystore fake that can be told to fail. |
| [nav_engine_defects_test.dart](test/qa_repro/nav_engine_defects_test.dart) | N1 and N2 driving the real `PortalSyncEngine`. Includes a happy-path test whose only job is to prove the harness is not rigged. |
| [fake_webview.dart](test/qa_repro/fake_webview.dart) | A scriptable portal behind a genuine `WebViewController`, via a fake `WebViewPlatform`. Records every injected script; a click only lands if the element is really in the document. |
| [js/extract.js](test/qa_repro/js/extract.js) | Parses the injected JavaScript straight out of the Dart sources, so the DOM tests track shipping code and break loudly if a script is renamed. |
| [js/dom_repro.js](test/qa_repro/js/dom_repro.js) | J1, J2, J3, C3-1 in jsdom. `npm install jsdom && node dom_repro.js`. |

The DOM suite still passes 8/8 at `e403641` — every one of those tests *documents* an open defect, so when J1/J2/J3/C3 are fixed each should be inverted to assert the new behaviour rather than deleted.

---

## Two things outside the brief

**A build-breaking double-paste.** [portal_sync.dart](lib/data/portal/portal_sync.dart) arrived mid-audit with `currentPage` pasted in twice — verbatim, including the doc comment — while `HEAD` already had it. The app would not compile. The duplicate was removed and the intended change left alone.

**This report was not published as an artifact.** Two attempts were made and both artifacts were deleted by the service within minutes, with no user action in between. This file is the durable handover.

---

*Line numbers are current as of 20 August 2026 against `e403641`. [sync_screen.dart](lib/screens/portal/sync_screen.dart) and [portal_sync.dart](lib/data/portal/portal_sync.dart) are both under active edit — re-pin before working from them.*
