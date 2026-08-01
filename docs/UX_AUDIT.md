# DOP Collect — UX Audit

**Round 2** · 30 July 2026
**Round 1:** 27 July 2026 (findings below are carried forward with their original IDs)
**Scope:** Full UI layer — theme, shell, 20 screens, all widgets, models, sync engine.
**Build state at audit time:** `flutter analyze` → **No issues found** · `flutter test` → **83 passed**
**Diff audited:** 3,264 insertions / 735 deletions across 40 files.

---

## The persona this was audited for

> **Ramesh-ji, 58.** DOP agent for 35+ years. Wears +2.5 reading glasses.
> Uses his phone for WhatsApp, calls and YouTube — nothing else.
> Thick fingers, slight tremor. Works outdoors in sunlight, on a scooter, in villages.
> Phone is a ₹9,000 Android. Reads Hindi faster than English.
> Knows RD, ASLAAS, "list", "defaulter". Does **not** know: portfolio, sync, OTA, offline-only AI, analytics, "Downloads".

Every finding is judged against *him*, not against a designer or a developer.

---

## Severity legend

| Tag | Meaning |
|---|---|
| 🔴 **BLOCKER** | He gets stuck, loses data, or loses money |
| 🟠 **MAJOR** | He misunderstands the app or does the wrong thing |
| 🟡 **MODERATE** | Friction, wasted time, erodes trust |
| 🔵 **POLISH** | Performance, consistency, future capability |

---

# ROUND 2 — SCORECARD

| Status | Count | IDs |
|---|---|---|
| ✅ **Closed** | 20 | B2, B3, B6, B7, B8, B9, L1, L3, M1, M3, M5, M6, M7, D2, D4, D6, D8, D11, P1, P2, P4 |
| ⚠️ **Partial** | 5 | L2, L4, L6, D1, D7 |
| 🔴 **Open** | 5 | B1, B4, D3(residual→N10), D9, D10 |
| 🆕 **New** | 12 | N1 – N12 |

---

# PART 0 — 🆕 NEW ISSUES INTRODUCED BY THE ROUND-1 FIXES

These did not exist in Round 1. They are the highest-priority work.

## N1. 🔴 "Create all lists" is B6 all over again, unguarded

**Where:** [saved_lists_screen.dart:98-134](lib/screens/lists/saved_lists_screen.dart#L98-L134)

`_createAllLists()` builds every list, saves them, and marks **every account deposited** — with no confirmation dialog.

The confirm was correctly added to the manual builder ([list_builder_screen.dart:130-151](lib/screens/lists/list_builder_screen.dart#L130-L151)), but this new one-tap path is the *more* likely tap: it is the first, blackest, full-width button on the Lists tab. There is still no bulk way to undo a Deposited mark.

**Fix**
- Same confirm sheet as the manual builder: N lists · M accounts · ₹total · "ये सब जमा मार्क होंगे".
- Ideally add a bulk undo (store the affected account numbers with the batch).

---

## N2. 🟠 The busy guard makes a dead button look live

**Where:** [saved_lists_screen.dart:394](lib/screens/lists/saved_lists_screen.dart#L394)

```dart
onPressed: _busy ? () {} : _createAllLists,
```

`PushButton` decides its enabled styling from `onPressed != null` ([push_button.dart:40](lib/widgets/push_button.dart#L40)). An empty closure is non-null, so during the run the button renders **fully enabled** and silently swallows taps. He taps it three more times.

**Fix**
- Pass `null`, not `() {}`. (The `_busy` overlay already covers the screen, so this is belt-and-braces — but the styling matters.)

---

## N3. 🟠 No `catch` around the batch save

**Where:** [saved_lists_screen.dart:104-133](lib/screens/lists/saved_lists_screen.dart#L104-L133)

The block is `try { … } finally { … }` with no `catch`. A DB error partway through the loop leaves **some accounts marked deposited and some not**, throws uncaught, and shows him nothing but a spinner that vanishes.

**Fix**
- `catch` → plain-language snackbar with a Retry, and report how many lists were saved before the failure.

---

## N4. 🔴 The manual builder now lists people who *don't* owe, first

**Where:** [lot_packing.dart:28-40](lib/models/lot_packing.dart#L28-L40) + [list_builder_screen.dart:78-82](lib/screens/lists/list_builder_screen.dart#L78-L82)

`priorityCompare` puts `behind < 0` (paid ahead) in the **top** tier:

```dart
if (behind < 0) return 2; // paid ahead — most reliable
if (behind == 0) return 1; // due this month — on time
return 0;                  // overdue
```

That tier is unreachable inside `eligible()` (which pre-filters `behind >= 0`), so the auto-packer is unaffected. But `ListBuilderScreen._sortByPriority` applies the same comparator to **all** accounts, unfiltered.

Result: opening **"New list"** now shows already-paid-ahead customers at the top and overdue ones at the bottom — backwards for the screen's entire purpose.

**Fix**
- Filter paid-ahead out of the manual builder too, or give the builder its own comparator that keeps `behind >= 0` first.

---

## N5. 🟡 The docs now contradict the code

**Where:** [lot_packing.dart:6](lib/models/lot_packing.dart#L6), [lot_packing.dart:46](lib/models/lot_packing.dart#L46)

Both still say *"most-unpaid first"*. The new comparator sorts overdue accounts **last**.

Beyond the stale comment, there's a product decision to make explicit: **defaulters now land in the final list** — the one most likely never to be built or submitted — while the dashboard simultaneously flags them in red under "Attention" and "Freezing soon (6 mo)". Reliable-first is a defensible strategy, but it currently fights the app's own alarm framing, silently.

**Fix**
- Make comparator and docs agree.
- Decide and state the intent in one line of UI ("सबसे भरोसेमंद पहले") so the ordering isn't a mystery.

---

## N6. 🟠 Sync can no longer remove anything

**Where:** [account_repository.dart:78-108](lib/data/account_repository.dart#L78-L108)

The B2 merge fix is correct and important — but it has no reconciliation pass. Accounts that are closed, matured or transferred away stay in his list **forever**, with no UI to delete one. Over a few years the list only grows.

**Fix**
- Track "seen in this sync". Accounts absent from a *complete* sync (not a partial/aborted one) get soft-flagged: greyed, moved to a "Closed?" bucket, with a manual "Remove" — never auto-deleted.

---

## N7. 🟠 The nav labels arrived at 9.5px

**Where:** [shell.dart:284-289](lib/shell.dart#L284-L289)

L5 asked for labels and got them — at **9.5px**, smaller than anything Round 1 criticised, on the one element that most needed to be readable.

Also the tap target is only ~40px wide: the `SizedBox` at [shell.dart:264-266](lib/shell.dart#L264-L266) constrains `height: 52` but leaves width intrinsic to the 40px icon pill.

**Fix**
- Labels to 11–12px; give each item a fixed ≥48dp width (5 items on a 360dp screen leaves room).

---

## N8. 🔴 `kEnablePortalSubmit = true` is shipped on, against its own comment

**Where:** [lot_detail_screen.dart:12-20](lib/screens/lists/lot_detail_screen.dart#L12-L20)

The constant's own doc says:

> *"ENABLED at the user's direction; the FIRST real use must be a supervised 1-account cash list to confirm the live portal behaves as the captured markup did."*

Live automation that keys installments and clicks Save on a banking portal is **on by default**, before that supervised test has happened. The design is right in the part that matters — the app never taps Pay All, so money only ever moves by a human hand — but the keying itself writes to a live system.

**Fix**
- Ship `false`. Flip it after the supervised 1-account run, or gate it behind a Settings toggle that is off until the first successful supervised submission.

---

## N9. 🟡 "Downloads" is a phone concept, not a postal one

**Where:** [saved_lists_screen.dart:379](lib/screens/lists/saved_lists_screen.dart#L379)

The tab holding *submitted* lists is labelled "Downloads (N)". He will go looking in his phone's Downloads folder.

**Fix**
- **Submitted** / जमा हो गई. Keep the per-card "Download" action — that word is fine on a button, wrong on a tab.

---

## N10. 🟠 Home now shows two different "this month" numbers

**Where:** [home_dashboard.dart:134-142](lib/screens/home_dashboard.dart#L134-L142)

- `_collectCard` (correct): `AccountFilter.toCollect` — only accounts that still owe.
- Immediately below it, the 46px yellow `FocalCard` labelled **"This Month's Collection"**: `AccountFilter.all` — *every* account × one installment, **including ones already deposited and paid ahead**.

M2 renamed the label from "Total Portfolio" but the underlying number is still not a collection figure. He will read the big yellow one — it's the largest thing on screen.

**Fix**
- Rename to "Monthly book" / "कुल मासिक", or drop the FocalCard now that `_collectCard` carries the real daily number.

---

## N11. 🟡 The rates "Reset" has no confirm

**Where:** [rd_rates_screen.dart:256-261](lib/screens/rd_rates_screen.dart#L256-L261)

A bare `TextButton` in the AppBar that discards every rate he ever added and restores the built-ins. D11 correctly guarded *delete* and *unsaved exit* — but not the one action that wipes everything.

**Fix**
- Same confirm dialog pattern as `_delete`.

---

## N12. 🔵 FocalCard's label is 3.84:1

**Where:** [summary_card.dart:47-49](lib/widgets/summary_card.dart#L47-L49)

`AppTheme.black.withValues(alpha: 0.55)` over the `#F0F67A → #E1EA4C` gradient measures **3.84:1** — below AA for 13px text.

**Fix**
- Alpha 0.75 (→ ~6:1). Same for the `0.7` sublabel at [summary_card.dart:60](lib/widgets/summary_card.dart#L60).

---

# PART 1 — 🔴 STILL OPEN FROM ROUND 1

## B1. Onboarding is untouched

**Where:** [onboarding_login.dart](lib/screens/onboarding_login.dart) — `git diff` is **empty**.

Still true, verbatim from Round 1:

- Five fields including User ID + Password before he sees a single screen. No skip path.
- The password field has **no show/hide eye** ([onboarding_login.dart:127](lib/screens/onboarding_login.dart#L127)). He types a portal password blind — and the portal's lockout is aggressive enough that the code caps auto-submits at 2 tries ([sync_screen.dart:267](lib/screens/portal/sync_screen.dart#L267)).
- Nothing validates the credentials; he learns they're wrong much later, inside a WebView.
- "Name" vs "Agent Name" still unexplained.
- ASLAAS still has no `e.g.` hint here (Settings has one).

**Fix**
- The eye toggle is a five-line change and removes the single most likely cause of a lockout. Do that first.
- Then: skip path, "Check login" verification, one Hindi line per field.

---

## B4. The captcha is untouched at its core

**Improved:** the debug "Capture page" icon is gone ✓, the raw diagnostic strings are now humane ✓ ([sync_screen.dart:251-257](lib/screens/portal/sync_screen.dart#L251-L257)), the status line went 11px → 13px ✓.

**Unchanged:** [sync_screen.dart:88](lib/screens/portal/sync_screen.dart#L88) still forces the desktop Chrome UA, so the full ~1200px Finacle portal renders on a 360px phone. No viewport injection, no zoom, no native input. When OCR fails he is still hunting 5-pixel glyphs with +2.5 glasses in sunlight.

The upscaled, binarized captcha is **already in hand** as a data URL at [sync_screen.dart:135-186](lib/screens/portal/sync_screen.dart#L135-L186).

**Fix**
- On OCR failure, `showModalBottomSheet`: captcha image at 240px wide, one large text field, numeric keypad, "नयी image" refresh, "Login" CTA. He never touches the WebView. ~40 lines.
- Add pinch-zoom + initial-scale meta injection as backup.

---

## D9. Every loading state is still a bare spinner

[home_dashboard.dart:105](lib/screens/home_dashboard.dart#L105), [account_list_screen.dart:80](lib/screens/account_list_screen.dart#L80), [saved_lists_screen.dart:304](lib/screens/lists/saved_lists_screen.dart#L304), [portfolio_screen.dart](lib/screens/portfolio_screen.dart) — centred `CircularProgressIndicator`, no text. Still no offline detection and no timeout copy; a 2G village sync hangs silently.

---

## D10. The tour is offered now, but still loses steps

**Improved:** it asks first ✓ ([shell.dart:52-71](lib/shell.dart#L52-L71)) and dropped from 10 steps to 6 ✓.

**Unchanged:** [product_tour.dart:135-136](lib/widgets/product_tour.dart#L135-L136) still advances on a tap **anywhere**, and [product_tour.dart:204-226](lib/widgets/product_tour.dart#L204-L226) still has no Back button. One accidental tap loses a step permanently. Copy is still English at 13.5px.

---

# PART 2 — ⚠️ PARTIALLY CLOSED

## L2. Type scale — half done

✅ `AppTheme.label` 11 → **13px** with tighter tracking ([app_theme.dart:75-76](lib/theme/app_theme.dart#L75-L76))
✅ Body sizes lifted across account rows, assistant answers, sync status
❌ The 14-size sprawl (10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 13.5 / 14 / 14.5 / 15 / 15.5 / 16 / 16.5) is unchanged — no 6-step scale
❌ **No "बड़ा अक्षर" (Large text) toggle** — still the single highest-value item for this persona
❌ And see **N7**: the new nav labels went in at 9.5px

## L4. Touch targets — mostly done

✅ Nav items now 52px tall ([shell.dart:265](lib/shell.dart#L265))
✅ Calculator + account steppers 34 → **44px** ([calculator_screen.dart:283-285](lib/screens/calculator_screen.dart#L283-L285), [portfolio_screen.dart:196-198](lib/screens/portfolio_screen.dart#L196-L198))
✅ Search row 46 → 48px ([account_list_screen.dart:125](lib/screens/account_list_screen.dart#L125))
❌ Print / Share / WhatsApp row still ~42px tall ([saved_lists_screen.dart:599](lib/screens/lists/saved_lists_screen.dart#L599))
❌ Nav items ~40px **wide** (see N7)

## L6. Status dots — bigger, still colour-only

✅ 8px → **12px with a soft ring** ([summary_card.dart:123-132](lib/widgets/summary_card.dart#L123-L132))
❌ Still no icon and no text state chip. A red-green colour-blind agent still cannot tell "Pending" from "Deposited".

## D1. Accounts list — the search is fixed, the list isn't

✅ Real hint "Search name or account number" + magnifier + inline ✕ ([account_list_screen.dart:130-158](lib/screens/account_list_screen.dart#L130-L158))
✅ Grey "Reset" button gone
✅ 250ms debounce ([account_list_screen.dart:51-61](lib/screens/account_list_screen.dart#L51-L61))
✅ Three distinct empty-state messages ([account_list_screen.dart:84-88](lib/screens/account_list_screen.dart#L84-L88))
❌ **Bucket screens still have no search** — `if (_isTab)` at [account_list_screen.dart:74](lib/screens/account_list_screen.dart#L74). Open "Defaulters" with 120 names and you can only scroll.
❌ No sort, no filter chips, no A–Z jump, no months-behind badge on the row
❌ No voice search

## D7. Assistant — much better, but the app around it is still English

✅ **Mic is now the primary control**: full-width, labelled, with the language toggle beside it ([assistant_screen.dart:640-650](lib/screens/assistant_screen.dart#L640-L650))
✅ Answer rows and detail cards are **tappable** → open the account ([assistant_screen.dart:186-194](lib/screens/assistant_screen.dart#L186-L194))
✅ `_kv` rows 12.5/13 → **13.5/14.5**; result tiles 13.5/11.5 → 14.5/12.5
✅ The developer-facing `online`/`offline` source chip is gone from the card header
✅ Dates use `dueDateLabel` / `openingDateLabel`
❌ The other 18 screens are still English-only. The one screen he can read is still the optional one.
❌ Still no Devanagari option anywhere

---

# PART 3 — ✅ CLOSED IN ROUND 2

| ID | Fix | Evidence |
|---|---|---|
| **B2** | Sync merges instead of `DELETE FROM accounts`; preserves `status`, Deep-Sync detail and serial in **both** repos; new `test/account_repository_merge_test.dart` | [account_repository.dart:78-108](lib/data/account_repository.dart#L78-L108), [account_repository.dart:171-192](lib/data/account_repository.dart#L171-L192) |
| **B3** | Deep Sync is reachable and labelled | [settings_screen.dart:91-97](lib/screens/settings_screen.dart#L91-L97), [settings_screen.dart:142](lib/screens/settings_screen.dart#L142) |
| **B6** | Manual list creation confirms before marking deposited | [list_builder_screen.dart:130-151](lib/screens/lists/list_builder_screen.dart#L130-L151) |
| **B7** | Sample data is **web-preview only**; the device shows an honest empty state + Sync CTA | [main.dart:29-34](lib/main.dart#L29-L34), [home_dashboard.dart:290-335](lib/screens/home_dashboard.dart#L290-L335) |
| **B8** | All three `_initials` `RangeError`s fixed | [home_dashboard.dart:254-258](lib/screens/home_dashboard.dart#L254-L258), [account_row.dart:90-93](lib/widgets/account_row.dart#L90-L93), [profile_view.dart:47-53](lib/screens/profile_view.dart#L47-L53) |
| **B9** | Calculator uses `DateTime.now()` | [calculator_screen.dart:50](lib/screens/calculator_screen.dart#L50) |
| **L1** | `inkMuted → #4E5A53` (~7:1), `inkFaint → #6B7770` (~4.6:1), documented in the theme | [app_theme.dart:20-24](lib/theme/app_theme.dart#L20-L24) |
| **L3** | `MediaQuery.withClampedTextScaling(1.0 – 1.3)` + `Flexible` on the overflow rows | [main.dart:88-95](lib/main.dart#L88-L95), [summary_card.dart:152-161](lib/widgets/summary_card.dart#L152-L161), [home_dashboard.dart:361-366](lib/screens/home_dashboard.dart#L361-L366) |
| **M1** | Groups + Lists merged into **one** "Lists" tab (6 nav items → 5); "lot" → "list" throughout the UI | [shell.dart:31-37](lib/shell.dart#L31-L37), [saved_lists_screen.dart:22-25](lib/screens/lists/saved_lists_screen.dart#L22-L25) |
| **M3** | `dueDateLabel` everywhere; due date coloured by `monthsBehind` (red / amber / green) | [account_row.dart:17-25](lib/widgets/account_row.dart#L17-L25), [portfolio_screen.dart](lib/screens/portfolio_screen.dart), [assistant_screen.dart](lib/screens/assistant_screen.dart) |
| **M5** | Settings grouped **DATA / TOOLS / APP**; one sync path + Deep Sync; "Review our App", "Payment Link" deleted; debug behind 7 version taps; Logout red at the bottom; version `0.9.22`; ASLAAS auto-saves on blur | [settings_screen.dart:57-60](lib/screens/settings_screen.dart#L57-L60), [settings_screen.dart:140-194](lib/screens/settings_screen.dart#L140-L194) |
| **M6** | Every `_soon(...)` CTA removed (Edit Profile, Add Collection, WhatsApp) | [portfolio_screen.dart:104-107](lib/screens/portfolio_screen.dart#L104-L107) |
| **M7** | The no-op "Calculate" button replaced with a live-update hint | [calculator_screen.dart:205-213](lib/screens/calculator_screen.dart#L205-L213) |
| **D2** | "Last synced: N hr ago", ambers past 24h | [home_dashboard.dart:261-287](lib/screens/home_dashboard.dart#L261-L287) |
| **D3** | Home restructured: collect card above the fold, First/Second half folded into one segmented panel, Portfolio behind "See more" | [home_dashboard.dart:124-174](lib/screens/home_dashboard.dart#L124-L174) *(residual issue → **N10**)* |
| **D4** | "About to Freeze · 6th month" → **"Freezing soon (6 mo)"** — fits at 360dp | [home_dashboard.dart:154](lib/screens/home_dashboard.dart#L154) |
| **D6** | Sync is a labelled black pill, not an unlabelled circle | [home_dashboard.dart:231-252](lib/screens/home_dashboard.dart#L231-L252) |
| **D8** | Global floating snackbar theme with `bottom: 96` so nothing hides under the nav pill | [app_theme.dart:109-118](lib/theme/app_theme.dart#L109-L118) |
| **D11** | Rates: 1–15% bounds on add *and* edit, delete confirm, unsaved-exit `PopScope`, current-quarter default | [rd_rates_screen.dart:85-92](lib/screens/rd_rates_screen.dart#L85-L92), [rd_rates_screen.dart:103-127](lib/screens/rd_rates_screen.dart#L103-L127), [rd_rates_screen.dart:219-244](lib/screens/rd_rates_screen.dart#L219-L244) *(residual → **N11**)* |
| **M4** | Undo added to the batch builder's remove | [batch_list_screen.dart:76-92](lib/screens/lists/batch_list_screen.dart#L76-L92) |
| **P1** | **Both** `BackdropFilter` blurs removed (panel + pill) — flat translucent fill instead | [glass_panel.dart:5-10](lib/widgets/glass_panel.dart#L5-L10), [glass_pill.dart:35-36](lib/widgets/glass_pill.dart#L35-L36) |
| **P2** | Search debounced | [account_list_screen.dart:51-61](lib/screens/account_list_screen.dart#L51-L61) |
| **P4** | Profile photos `base64Decode`d once into `Uint8List`, not per frame | [home_dashboard.dart:36](lib/screens/home_dashboard.dart#L36), [profile_view.dart:23](lib/screens/profile_view.dart#L23) |

**Also landed (not requested in Round 1, worth noting):**
- SQLite is now encrypted (`sqflite_sqlcipher`) — [account_repository.dart:1](lib/data/account_repository.dart#L1)
- Cheque modes with per-account cheque number + bank account capture
- 50-accounts-per-list portal rule enforced in both the packer and the manual builder
- Real E-Banking reference captured back onto a submitted list, with a "Not submitted yet" state so the local `L…` id is never mistaken for it — [lot_detail_screen.dart:247-268](lib/screens/lists/lot_detail_screen.dart#L247-L268)

---

# PART 4 — 🔵 STILL UNADDRESSED

## Performance

**P3** — whole-tree rebuilds: `_dataVersion` re-keys all five pages ([shell.dart:145-161](lib/shell.dart#L145-L161)); the New Accounts dropdown rebuilds the entire Home ListView ([home_dashboard.dart:559-564](lib/screens/home_dashboard.dart#L559-L564)).

## Missing for the actual job

| Gap | Why it matters to him |
|---|---|
| **No "आज का काम" route view** | He plans his day by locality and due date. |
| **No call / WhatsApp from a row** | Half his collection work is reminder calls. The WhatsApp button was *removed* in M6 rather than implemented — correct for now, but the capability is still missing. |
| **No customer receipt** | He hands over paper; the app can't generate an acknowledgement. |
| **No backup / export** | Everything lives in one (now encrypted) SQLite file on one phone. Lose the phone, lose 400 accounts. Nothing warns him. |
| **No Devanagari option** | He may read देवनागरी faster than Roman-script Hindi. No language setting exists. |
| **No accessibility semantics** | Zero `Semantics` widgets; tooltips require long-press. TalkBack reads unlabelled circles. |

---

# NEXT ROUND — PRIORITISED

## Immediate (data integrity — do these first)

- [ ] **N1** — confirm dialog on "Create all lists" before marking accounts deposited
- [ ] **N2** — pass `null`, not `() {}`, to the busy button
- [ ] **N3** — `catch` + Retry around the batch save
- [ ] **N4** — stop the manual builder sorting paid-ahead customers to the top
- [ ] **N5** — make `lot_packing` comments match the comparator; decide and surface the ordering intent

## Safety

- [ ] **N8** — ship `kEnablePortalSubmit = false` until the supervised 1-account run
- [ ] **N11** — confirm dialog on the rates "Reset"

## Legibility (quick wins)

- [ ] **N7** — nav labels 9.5 → 11–12px; fixed ≥48dp item width
- [ ] **N12** — FocalCard label alpha 0.55 → 0.75; sublabel 0.7 → 0.85
- [ ] **N9** — "Downloads" tab → "Submitted"
- [ ] **N10** — rename or drop the FocalCard so Home shows one "this month" number
- [ ] **L4** — Print/Share/WhatsApp row to 48dp
- [ ] **L6** — add an icon + text state chip alongside the status dot

## The two that still matter most

- [ ] **B1** — password eye toggle *(5 lines, prevents lockouts)*, then skip path + credential check
- [ ] **B4** — native captcha bottom sheet using the data URL you already extract

## Then

- [ ] **N6** — sync reconciliation for closed/matured accounts (soft-flag, never auto-delete)
- [ ] **L2** — collapse the type scale; ship the **"बड़ा अक्षर"** toggle
- [ ] **D1** — search + sort on bucket screens; months-behind badge on the row
- [ ] **D7** — Hindi/Hinglish across the whole app, not just the Assistant
- [ ] **D9** — skeletons, offline detection, timeout copy
- [ ] **D10** — tour: advance only on Next, add Back

---

## If you only fix three

1. **N1** — one unguarded tap still marks his whole book deposited, irreversibly.
2. **N4** — the list builder currently sorts the wrong people to the top, every time he opens it.
3. **B4** — the captcha in a desktop page is still what will make him give up before he ever sees his data.
