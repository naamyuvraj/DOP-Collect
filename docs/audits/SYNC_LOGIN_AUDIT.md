# DOP Collect — Sync Login Audit & Re-verification

**Date:** 20 August 2026 · branch `removation` · verified at `e403641` (1.0.0+44) · Flutter 3.44.6
**Scope:** the portal sync login flow end to end — [sync_screen.dart](lib/screens/portal/sync_screen.dart), [portal_sync.dart](lib/data/portal/portal_sync.dart), [credentials.dart](lib/data/credentials.dart), [captcha_solver.dart](lib/data/portal/captcha_solver.dart), and the daily-login counter in [app_settings.dart](lib/data/app_settings.dart).
**Triggered by:** three field reports — the captcha fills but Login is never pressed; the password is sometimes never typed; login succeeds but Accounts never opens.
**At `e403641`:** `flutter test test/qa_repro/` **11/11 green** · DOM suite **8/8** · `flutter analyze` clean.

Nine defects were found. Three were fixed in [`1cf4e3e`](#fixed) and are
**re-verified fixed here**. Since then C3, J1 and J2 have been fixed too, and
two further findings this audit never had — [V1](#v1) and [H1](#h1) — were found
and fixed on 26 Aug. **Nothing on this list is open.** [A1](#a1) is the one to
treat with suspicion: it is fixed, but it was never reproduced in the first
place, so there is no test that would have failed before the change.

---

## Status of this document

**Updated 26 August 2026.** The N1 warning that used to sit here is resolved:
`_maxNavClicks` is present in [portal_sync.dart](lib/data/portal/portal_sync.dart)
and the N1 acceptance test passes in the working tree. J2 has also been fixed
there — `_clickLinkByText` now resolves **down** to the anchor before walking up,
and refuses to report success for anything that is not an `a`/`button`/`input`.

Fixed since: **C3**, **J1**, **A1**, **J3**, and two findings this audit did not
have ([V1](#v1), [H1](#h1)). **N2** was fixed in the working tree too — this
document called it open for six days after it stopped being open, which is the
usual failure mode of a status table nobody re-reads. Line numbers below predate
all of that; re-pin before working from them.

---

## Status

Defect IDs match the test group names in [test/qa_repro/](test/qa_repro/) — those are authoritative.

| ID | Defect | Severity | Status at `e403641` |
|---|---|---|---|
| [C1](#c1) | The daily auto-login budget is spent by *successful* logins and never reset | 🔴 CRITICAL | ✅ **Fixed** — re-verified |
| [C2](#c2) | A Keystore fault kills autofill for the whole screen, silently | 🟠 HIGH | ✅ **Fixed** — re-verified |
| [N1](#n1) | One dropped click becomes 20 clicks in 5.6 s | 🟠 HIGH | ✅ **Fixed** — re-verified (the revert is undone) |
| [C3](#c3) | The 900 ms captcha timer races the Keystore read; auto-submit then abandoned permanently | 🔴 CRITICAL | ✅ **Fixed** — 26 Aug |
| [J1](#j1) | The captcha fill fires no key events and never focuses the field | 🟠 HIGH | ✅ **Fixed** — 26 Aug |
| [J2](#j2) | The Enquire-link fallback clicks the wrapping `<td>`, then reports success | 🟠 HIGH | ✅ **Fixed** — in the working tree |
| [A1](#a1) | Auto-start probes once, with no settle and no retry | 🟠 HIGH | ✅ **Fixed** — 26 Aug (📖 still unproven) |
| [N2](#n2) | A spent session is misdiagnosed as a missing link; the remedy shown cannot work | 🟡 MEDIUM | ✅ **Fixed** — in the working tree |
| [J3](#j3) | The captcha OCR runs on every page of the walk | 🟡 MEDIUM | ✅ **Fixed** — 26 Aug |
| [V1](#v1) | The WebView lays the desktop portal out at **phone width** | 🔴 CRITICAL | ✅ **Fixed** — 26 Aug |
| [H1](#h1) | The portal's reCAPTCHA is invisible to the app, which keeps submitting into it | 🔴 CRITICAL | ✅ **Fixed** — 26 Aug |

**[V1](#v1) is the one that was underneath everything.** It is not in the
original nine because this audit never looked at how the WebView was
*configured* — only at what it did once a page was up. A desktop page laid out
at 360 CSS px is the common ancestor of "the login screen looks wrong", "the
reCAPTCHA doesn't work" and a fair share of the mis-taps.

**Provenance.** ✅ MEASURED means a test in `test/qa_repro/` executes the shipping code and the numbers quoted are its output. 📖 INFERRED means code reading only, never executed — [A1](#a1) is the only one.

---

## Symptom → cause

More than one cause per symptom is why it reads as random. Struck-through causes are fixed.

| Reported as | Caused by | Pattern to expect |
|---|---|---|
| "Fills the captcha but gets stuck there, I have to tap Login" | ~~C1~~, ~~C3~~, ~~J1~~ | All three now fixed. C1 was deterministic from the fifth portal screen of the day; C3 hit cold starts and cleared on a warm one; J1 was constant. |
| "Sometimes forgets to fill the password" | ~~C3~~, ~~C2~~ | C3 filled it a moment too late — it did appear, just after the decision was taken. C2 never filled it and never recovered until reinstall. |
| "Gets logged in but cannot open Accounts" | ~~N1~~, ~~J2~~, **[A1](#a1)**, **[N2](#n2)** | A1 shows as a screen that does nothing at all. N2 misnames a spent session. |
| "It fills the captcha, the login fails, then a reCAPTCHA comes and never fills" | **[H1](#h1)**, **[V1](#v1)** | H1 is the cause and V1 is why it could not be rescued by hand. Both fixed 26 Aug; each rejected login was itself a reason for the portal to keep the challenge up. |
| "The login screen looks broken / squashed" | **[V1](#v1)** | Constant on every handset, and the reason the page never looked like the one in other agents' apps. |

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
### N1 — dropped click became a click storm · 🟠 HIGH · ✅ FIXED

**Was:** a four-hop outer loop wrapping a four-slice inner loop, every slice re-clicking the Enquire link. Measured: **20 clicks in 5.64 s**, no backoff, no cap. Page-finish fires even when the DOM never changes, so `_awaitLoad` returned immediately and the 11 s slice never applied — the whole budget went out as rapid-fire clicks on one Finacle link. That is the traffic shape that trips the stale-transaction-token guard, making this a plausible *cause* of the poisoned sessions in [N2](#n2) rather than only a victim.

**Now:** a hard ceiling of `_maxNavClicks = 4` for the whole walk with a doubling gap. The time budget is unchanged — it is spent waiting instead of clicking.

**Verified at `e403641`:** `totalClicks=4 elapsed=8926ms`, acceptance test green.

---

## Open

<a id="c3"></a>
### C3 — The captcha timer races the Keystore read, and losing forfeits auto-submit for good
**🔴 CRITICAL · ✅ MEASURED · ✅ FIXED 26 Aug**

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

**Now.** Both halves, as prescribed.

*The ordering is chained, not timed.* `_armCaptchaSolve()` awaits
`_autofillIfLogin()` — which awaits `_credsReady` — before it reads the picture.
There is no delay that is both long enough for a slow Keystore and short enough
not to feel broken, so the wall clock is gone entirely. A warm start is now
**faster** than the old 900 ms: `_credsReady` is already resolved, so the only
wait is a 400 ms settle for the captcha `<img>` to paint — and being early
*there* is recoverable, because the extractor reports `loading` and retries
itself 6 × 600 ms. Being early on the credentials was not.

*Losing re-arms instead of surrendering.* `_ensureCredsInForm()` replaces the
gate that returned. On an empty form it waits for `_credsReady`, runs the
autofill again, settles 300 ms and re-reads. Only then does it hand the screen
back. It is safe to call repeatedly — the autofill only writes a field that is
empty, so it can never overwrite something the agent typed.

*And `_credsReady` was made unable to break the new dependency.* It is now built
from `_loadCredentials()`, which catches and times out at 8 s — a wedged
Keystore (direct boot, a stuck vendor provider) can no longer leave the captcha
solve waiting behind an unresolved future. `Credentials.load()`'s last throwing
path was closed at the same time: the `SharedPreferences.getInstance()` call sat
*above* its try/catch. That was survivable when only the autofill depended on
it; it is not survivable now that the captcha does too.

**Verified.** `test/qa_repro/login_autofill_defects_test.dart` — 13 green,
including a prefs store that fails every call and a source-shape guard that
fails if the 900 ms timer or the surrendering gate comes back. SyncScreen itself
still cannot be widget-tested here (SQLCipher-backed `AccountRepository` plus a
`WebViewWidget` platform), which is why the ordering is asserted from the source
the way `js/extract.js` does it.

---

<a id="j1"></a>
### J1 — The captcha fill fires no key events and never focuses the field
**🟠 HIGH · ✅ MEASURED (conditional) · ✅ FIXED 26 Aug**

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

**Now.** `_fillCaptchaJs` focuses the field and dispatches
`keydown → keypress → input → change → keyup → blur`, in that order — a handler
that reads `.value` on `keyup` sees the finished value. The selector was
anchored on the portal's real field name (`AuthenticationFG.VERIFICATION_CODE`,
from the live capture) ahead of the loose `[id*="captcha"]` fallback, so a junk
read can no longer land in an unrelated box on the page that matters.

**Verified.** `dom_repro.js` J1-1 and J1-2 were **inverted** — they used to
assert the defect, they now assert the fix and fail loudly on regression. 9/9.
Still conditional in the same way it always was: this proves our side is
correct, not that the DOP page gates on `keypress`.

---

<a id="j2"></a>
### J2 — The Enquire-link fallback clicks the wrapping cell and reports success
**🟠 HIGH · ✅ MEASURED (conditional) · ✅ FIXED in the working tree**

**Where:** [portal_sync.dart](lib/data/portal/portal_sync.dart) · `_clickLinkByText`

It searches `a, input, button, span, td` by substring and clicks `els[i].closest('a') || els[i]`. Two facts collide: in document order an ancestor precedes its descendant, so a `<td>` containing the link is always examined **before** the link itself; and `closest()` walks **up**, so from that `<td>` it never finds the anchor inside it.

The result is a click on the table cell — which navigates nowhere — and a return of `'true'`, so the caller believes it moved. N1's fix bounds how much that false success costs, but does not stop it being wrong.

The fast path is fine: when the anchor carries `name` or `id` containing *Enquire*, `_clickSelector` handles it correctly and this never runs. The defect only bites when it does not — which needs a DOM capture to confirm.

**Now.** `_clickLinkByText` resolves **down** first —
`els[i].querySelector('a, button, input')` — then up via `closest`, then the
element itself; and it returns `'false'` unless what it clicked is an `a`,
`button` or `input`, so a non-navigating click no longer masquerades as a
successful one. Not this pass's work: it was already in the working tree.

**Verified.** `dom_repro.js` J2-1/J2-1b/J2-2/J2-3 assert the fixed behaviour and pass.

---

<a id="a1"></a>
### A1 — Auto-start probes once, with no settle and no retry
**🟠 HIGH · 📖 INFERRED — never reproduced · ✅ FIXED 26 Aug**

**Where:** [sync_screen.dart](lib/screens/portal/sync_screen.dart) · `_maybeAutoStart` · [portal_sync.dart](lib/data/portal/portal_sync.dart) · `isAuthenticated`

`_maybeAutoStart()` runs straight off the page-finish callback and calls `isAuthenticated()` exactly once, with no settle delay — unlike every other DOM read in the engine, which calls `_settle()` first. The probe looks for `#Accounts` / `a[name="HREF_Accounts"]`.

`onPageFinished` fires at document load. If the dashboard menu is written by a deferred script or an XHR — ordinary for this portal — the probe returns false. The post-login dashboard is the last navigation of the session, so `onPageFinished` never fires again and **nothing retries**. The screen sits on a perfectly good logged-in dashboard doing nothing.

**Not reproduced.** Exercising it needs a widget test of `SyncScreen`, which pulls in the SQLCipher-backed `AccountRepository` and a `WebViewWidget` platform — out of scope for this pass. Rated High on reasoning, and it is the finding most worth confirming on a handset before spending effort on it.

**Now.** `_pollAuthenticated()` asks for up to 8 s with a 400 ms settle before
the first read and 700 ms between, instead of one unsettled probe. It stops
early when the login form is still on screen — during the login phase this fires
on every page-finish, and re-asking a page that is plainly still requesting a
password is time spent for nothing. So the full budget is only ever spent on a
page that is neither the login form nor recognisably the dashboard, which is the
deferred-render case it exists for. `_autoStartPolling` keeps one poll in flight
at a time, since the poll outlives the callback that starts it.

**Still unproven.** This is the honest caveat: A1 was never reproduced, so
nothing here failed before the change and nothing proves the deferred-render
theory was right. The change is cheap and strictly safer than one probe, but if
"the screen does nothing after login" comes back, this is not the thing that was
ruled out. Four source-shape guards in
[login_autofill_defects_test.dart](test/qa_repro/login_autofill_defects_test.dart)
stop it reverting silently — they are not evidence it was ever broken.

---

<a id="n2"></a>
### N2 — A spent session is misdiagnosed as a missing link, and the remedy shown cannot work
**🟡 MEDIUM · ✅ MEASURED · ✅ FIXED in the working tree**

**Where:** [portal_sync.dart](lib/data/portal/portal_sync.dart) · `navigateToAccountList` (no blocked-page probe) · `_isBlockedPage` (the probe that exists)

`_isBlockedPage()` detects Finacle's stale-token guard — *"close this window and try accessing the application in a new browser window"*. It is called from three places in the file, and `navigateToAccountList` is not one of them.

So when a session is poisoned, navigation returns a bare `false`, indistinguishable from "the link was not found", and `_sync()` renders that as *"Open Accounts → Agent Inquire and Update, then tap Sync."* — advice that cannot work, because only a fresh login clears a spent token. The agent follows it, fails, and repeats.

```
test/qa_repro/nav_engine_defects_test.dart
  EVIDENCE N2: 9 scripts injected, 5 DOM reads,
               enquireClicks=1                             PASS
```

**Now.** Exactly the prescribed API change, already in the working tree — not
this pass's work. `navigateToAccountListDetailed` returns a `NavResult` carrying
a typed `NavFailure` (`sessionExpired` / `blocked` / `notLoggedIn` / `stalled`),
`_walkToList` probes `_isSessionExpired()` and `_isBlockedPage()` both inside
the loop and once more on the way out, and `NavResult.message` phrases each as
the next thing to do rather than a diagnosis — *"The portal ended this session.
Log in again, then tap Sync."*

**Verified.** `nav_engine_defects_test.dart`, group *"N2 — a spent session must
not be reported as a missing link"* — green, including *"landing back on the
login page is not a navigation failure"*.

---

<a id="j3"></a>
### J3 — The captcha OCR runs on every page of the sync, not just the login page
**🟡 MEDIUM · ✅ MEASURED · ✅ FIXED 26 Aug**

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

**Now.** All three parts.

*The solver runs only on the login page.* `_autofillCaptcha` probes for
`AuthenticationFG.VERIFICATION_CODE` before doing anything, so the 47-page walk
no longer runs the scorer at all.

*Size alone is no longer enough.* The acceptance threshold went from 3 to **5**,
and size tops out at 4 (3 captcha-sized + 1 wide). An image now needs a name
that says captcha (+5) or a position inside the verification field's own block
(+4). Decorative furniture that happens to be captcha-shaped scores **−6** —
which matters here specifically, because the portal's refresh icon
(`reset.jpg`, `#TEXTIMAGE`) sits right beside the captcha and would otherwise
ride in on proximity. The penalty is matched against src/id/class/name only,
never `alt`: the live captcha's alt text is *"Please Click On The Icon Next For
Audio"*, and matching "icon" in **that** would have penalised the one image
we're looking for. Measured on the live DOM shape: IMAGECAPTCHA **13**, the
refresh icon **2**.

*The write-back selector is tight, and this got urgent.* `[id*="captcha" i]`
matches `#g-recaptcha-response`. That was harmless while this portal had no
reCAPTCHA — [H1](#h1) says it does now, so an OCR read could have been written
straight into the challenge's token field. The fallback now skips
`g-recaptcha` / `h-captcha` / `captcha-response` by name and accepts only a
text-like input.

**Verified.** `dom_repro.js` J3-1/J3-1b/J3-1c/J3-2/J3-2b — the two originals
**inverted**, three added to prove the tightening did not break the real portal,
a renamed captcha, or a nameless one sitting beside the box. 12/12.

---

## What testing changed about the first read

Two claims from the initial code audit did not survive measurement. Recorded so nobody works from the earlier version.

- **The guard page is not thrashed.** The first read said the engine keeps clicking a dead session. Measured: exactly **one** Enquire click, because the guard page has no Enquire link to find. The real defect there is misdiagnosis ([N2](#n2)), not thrash — and the thrash lived on the dropped-click path instead ([N1](#n1)), where it was arguably what *created* the guard page.
- **"About three minutes of nothing" applied to one path only.** It held when page-finish never fired (4 × 4 × 11 s ≈ 2 min 56 s). When page-finish did fire, the identical loop burned all 20 clicks in 5.6 s — far worse for the portal, far shorter for the user.

---

<a id="v1"></a>
### V1 — The WebView lays the desktop portal out at phone width
**🔴 CRITICAL · ✅ MEASURED · ✅ FIXED 26 Aug**

**Where:** `webview_flutter_android` 4.13.0, `android_webview_controller.dart:151` · both portal screens

Not one of the original nine, because this audit only ever looked at what the
app did *once a page was up* — never at how the WebView was configured.

`webview_flutter_android` constructs **every** controller with
`setUseWideViewPort(false)`. Nothing in the app overrode it. So we shipped a
desktop User-Agent — which makes the server send the full desktop pages — with a
**phone layout viewport**, which then reflowed those pages into ~360 CSS px. The
plugin also sets `setLoadWithOverviewMode(true)`, which does nothing at all
without the wide viewport, so the setting that *looks* like it handles this was
inert.

The portal's login page declares no `<meta name="viewport">` anywhere — verified
against [recon/live/01_login__before_submit.html](recon/live/01_login__before_submit.html).
A page like that has two rendering modes on a phone, and we were getting the
wrong one:

| | Layout viewport | Result |
|---|---|---|
| What we shipped | ~360 px | Fixed-width tables collide, columns clip off the right edge |
| What every other agent app does | 980 px, scaled to fit | Desktop layout intact, pinch to zoom — Chrome's "Request desktop site" |

Desktop HTML, phone layout: the worst of both. It is the common ancestor of "the
login screen looks wrong", "the reCAPTCHA doesn't work" ([H1](#h1) — a 300×78
widget landing somewhere unreachable), and an unknown share of mis-taps.

**Now.** [portal_webview.dart](lib/data/portal/portal_webview.dart) —
`applyDesktopViewport()` sets `setUseWideViewPort(true)`, `setTextZoom(100)` (a
phone on a large system font scales WebView text up to 130% and overflows a
fixed-width table just as badly — a "broken layout" that only reproduces on the
handsets whose owners turned the text size up) and `enableZoom(true)`. Applied
in both [sync_screen.dart](lib/screens/portal/sync_screen.dart) and
[deep_sync_screen.dart](lib/screens/portal/deep_sync_screen.dart) **before** the
first `loadRequest`, so the login page is never laid out narrow even once. A
viewport-meta injection covers WKWebView, which has no equivalent setting; it
fires only when the page declares no viewport of its own.

`webview_flutter_android` moved from a transitive to a direct dependency for
`AndroidWebViewController`. No new native code.

**Not verified on a handset.** The default is certain from the plugin source and
the missing viewport meta is certain from the capture. What the fixed layout
actually looks like on the phone is the thing to confirm.

---

<a id="h1"></a>
### H1 — The portal's reCAPTCHA is invisible to the app, which keeps submitting into it
**🔴 CRITICAL · ✅ MEASURED · ✅ FIXED 26 Aug**

**Where:** [sync_screen.dart](lib/screens/portal/sync_screen.dart) · `_autofillCaptcha`

The portal raises a Google reCAPTCHA after it has rejected a login. It is not in
the August captures — `grep -ci recaptcha` returns **0** on both
`01_login__before_submit.html` and `02_login__after_submit_failed.html` — so it
either postdates them or only appears past some failure count. Either way there
were **zero** references to it anywhere in `lib/`.

So nothing in this screen knew the widget existed. `_autofillCaptcha` kept
OCR'ing the picture captcha, filling it, finding the Log in button enabled and
clicking it — into a form the portal was never going to accept. That is a
feedback loop, not just a wasted click: every rejection is a reason for the
portal to keep demanding a challenge, and each one spent an attempt out of the
ten standing between the agent and a Finacle account lockout. The app was
feeding the thing that blocked it. [V1](#v1) is why he could not rescue it by
hand.

**Now.** `_humanCheckJs` reports `{present, solved}` — `solved` reads the
response token the widget writes when a person passes it. When a challenge is
present and unsolved, auto-submit is **held**, the widget is scrolled into view,
and the status bar says what to do. Once the agent ticks the box,
`_submitAfterHumanCheck` finishes the login for him (3-minute cap, and it stops
early if he submitted it himself). `_noteHumanCheck` on page-finish covers the
case where the challenge appears *instead of* the picture captcha, which the
solver would otherwise never look at. Every Log in click now routes through one
`_clickLoginAndJudge` so the lockout accounting cannot drift between callers.

**This is not a bypass and cannot become one.** Nothing here reads, guesses or
works around the challenge — it only observes a token a person produces. Until
the box is ticked it does nothing at all. The value is the attempts it *stops
spending*.

**Not verified against the live challenge.** The detection is written against
the standard reCAPTCHA/hCaptcha markup. If the portal's is non-standard, **Copy
page HTML** on the challenge page settles it in one capture — that page is not
in `recon/live/` and should be.

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

Nothing on the defect list is open. What is left is **confirmation**, not code —
every fix since 20 August was verified against constructed pages and the
captures in `recon/live/`, and none of it has been near a handset or the live
portal.

| Step | What | Why here | Size |
|---|---|---|---|
| 1 | *Handset run of the login phase* | [V1](#v1) changes what every screen looks like and is confirmed only from the plugin source. Everything else is easier to judge once the layout is right. | XS |
| 2 | *Copy HTML on the challenge page* | The one page `recon/live/` does not have. Settles whether [H1](#h1)'s detection matches the portal's real markup — the detection is written against standard reCAPTCHA/hCaptcha and nothing has checked that assumption. | XS |
| 3 | *Watch a cold start* | [C3](#c3)'s whole point is the first page load after a cold start. The trace now prints `creds: loaded in NNNms` — if that number is under ~400 ms on this handset, the race this fixed was never being lost on it. | XS |
| 4 | [A1](#a1) | Fixed, never reproduced. If "the screen does nothing after login" recurs, start here — and get a capture of the dashboard this time. | S |
| 5 | *Invert the C3-1 jsdom test* | It still asserts a precondition rather than the fix, which is fine, but it reads like an open defect. | XS |

---

## Test assets

Committed under [test/qa_repro/](test/qa_repro/) as of `1cf4e3e`.

| File | What it does |
|---|---|
| [login_autofill_defects_test.dart](test/qa_repro/login_autofill_defects_test.dart) | C1, C2, C3 against the real `AppSettings` and `Credentials`, with a Keystore fake and a prefs store that can each be told to fail. **13/13.** Includes source-shape guards on C3's ordering, because SyncScreen cannot be widget-tested here. |
| [nav_engine_defects_test.dart](test/qa_repro/nav_engine_defects_test.dart) | N1 and N2 driving the real `PortalSyncEngine`. Includes a happy-path test whose only job is to prove the harness is not rigged. |
| [fake_webview.dart](test/qa_repro/fake_webview.dart) | A scriptable portal behind a genuine `WebViewController`, via a fake `WebViewPlatform`. Records every injected script; a click only lands if the element is really in the document. |
| [js/extract.js](test/qa_repro/js/extract.js) | Parses the injected JavaScript straight out of the Dart sources, so the DOM tests track shipping code and break loudly if a script is renamed. |
| [js/dom_repro.js](test/qa_repro/js/dom_repro.js) | J1, J2, J3, C3-1 in jsdom. **9/9.** J1 and J2 are inverted — they assert the fix now, not the defect. `npm install jsdom && node dom_repro.js`. |

The DOM suite still passes 8/8 at `e403641` — every one of those tests *documents* an open defect, so when J1/J2/J3/C3 are fixed each should be inverted to assert the new behaviour rather than deleted.

---

## Two things outside the brief

**A build-breaking double-paste.** [portal_sync.dart](lib/data/portal/portal_sync.dart) arrived mid-audit with `currentPage` pasted in twice — verbatim, including the doc comment — while `HEAD` already had it. The app would not compile. The duplicate was removed and the intended change left alone.

**This report was not published as an artifact.** Two attempts were made and both artifacts were deleted by the service within minutes, with no user action in between. This file is the durable handover.

---

*Line numbers below the Status section are as of 20 August 2026 against `e403641` and predate the 26 August changes. [sync_screen.dart](lib/screens/portal/sync_screen.dart) and [portal_sync.dart](lib/data/portal/portal_sync.dart) are both under active edit — re-pin before working from them.*
