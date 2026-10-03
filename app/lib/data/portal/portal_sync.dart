import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../models/rd_account.dart';
import 'agent_detail_parser.dart';
import 'agent_list_parser.dart';
import 'portal_dom.dart';
import 'aslaas_report_parser.dart';
import 'saved_installments_parser.dart';

/// What happened when the engine tried to turn a page.
///
/// Three states, not two: "I moved", "there was nothing to move to", and "I
/// tried and the page never came back". The last one is a failure and must not
/// be mistaken for the second.
enum PageAdvance { moved, lastPage, stalled }

/// Why the walk could not reach the account list.
///
/// This used to be a bare `false`, and the screen rendered every one of these
/// as "Open Accounts → Agent Inquire and Update, then tap Sync." For a spent
/// session that advice cannot work — only a fresh login clears a dead token —
/// so the agent followed it, failed, and repeated. Keep the reasons apart so
/// the remedy offered is one that can actually succeed.
enum NavFailure {
  /// Reached it. Not a failure.
  none,

  /// The portal's "Your Session is Expired" interstitial. Needs a new login.
  sessionExpired,

  /// Finacle's stale-transaction-token guard. Also needs a new login.
  blocked,

  /// We clicked the right things and the list never rendered.
  stalled,

  /// Login has not happened (or has lapsed back to the login page).
  notLoggedIn,
}

/// Outcome of [PortalSyncEngine.navigateToAccountListDetailed].
class NavResult {
  const NavResult(this.reached,
      {this.failure = NavFailure.none, this.hops = 0});
  final bool reached;
  final NavFailure failure;

  /// How many navigating clicks the walk spent. Kept for the acceptance tests,
  /// which assert this stays small — see [PortalSyncEngine._maxNavClicks].
  final int hops;

  /// What to tell the agent — phrased as the next thing to do, not as a
  /// diagnosis. He is standing in someone's doorway holding cash.
  String get message {
    switch (failure) {
      case NavFailure.none:
        return '';
      case NavFailure.sessionExpired:
      case NavFailure.notLoggedIn:
        return 'The portal ended this session. Log in again, then tap Sync.';
      case NavFailure.blocked:
        return 'The portal blocked this session. Log in again, then tap Sync.';
      case NavFailure.stalled:
        return 'Could not open the account list. Check the signal and tap '
            'Sync again.';
    }
  }
}

/// Result of an auto-sync attempt.
class SyncResult {
  final List<RdAccount> accounts;
  final bool reachedList;
  final String? error;

  /// True only when every page the portal advertised was actually read.
  ///
  /// A partial run still returns the accounts it managed to read — they are
  /// worth merging — but the caller must NOT treat it as a finished sync:
  /// stamping `last_sync` or reporting the count as the agent's book size off a
  /// short read is how a stall turns into a wrong number on the dashboard.
  final bool complete;

  /// Rows that looked like accounts but had an unreadable due date or
  /// denomination, and were dropped rather than stored as a sentinel. See
  /// [AgentListParser.parse]. Non-zero means the agent is being shown fewer
  /// accounts than the portal holds, and he is told so.
  ///
  /// [rejectedAccounts] names them, and the merge needs those names: a complete
  /// sync closes every account it did not see, so a row this parser could not
  /// read must still count as SEEN or the customer is closed over one bad cell.
  final int rejected;

  /// Rows that are real accounts with no next installment due — the portal
  /// leaves that cell blank once an RD reaches its 60-month term. They are not
  /// corrupt data and they are not [rejected]; they are simply finished, and
  /// counting them apart is what keeps a book full of maturities from reading
  /// as a book full of parse failures.
  final List<MaturedRow> maturedRows;
  int get matured => maturedRows.length;

  /// Account numbers behind [rejected] — seen on the portal, not readable.
  final Set<String> rejectedAccounts;

  const SyncResult(this.accounts,
      {this.reachedList = true,
      this.error,
      this.complete = true,
      this.rejected = 0,
      this.rejectedAccounts = const <String>{},
      this.maturedRows = const <MaturedRow>[]});
}

/// Result of preparing a bulk list on the portal (mode + account selection +
/// Save). [selected] are the account numbers actually ticked; [saved] is true
/// once the portal accepted the Save and moved to the installment screen.
class ListPrepResult {
  final Set<String> selected;
  final int requested;
  final bool saved;
  final String? error;
  const ListPrepResult(this.selected, this.requested,
      {this.saved = false, this.error});
  Set<String> missing(Set<String> targets) => targets.difference(selected);
}

/// Cheque details keyed per account for DOP / Non-DOP cheque submission.
class ChequeInfo {
  final String chequeNo;
  final String bankAccount; // bank a/c number printed on the cheque
  final String bankName;
  const ChequeInfo(
      {required this.chequeNo, required this.bankAccount, this.bankName = ''});
}

/// Outcome of keying installments on the selected-accounts screen. [saved] rows
/// reached Modified=YES; [rebates] is what the portal computed per account.
class InstallmentFillResult {
  /// How many rows that *needed* explicit keying reached Modified=YES.
  final int saved;

  /// How many rows needed explicit keying (advance >1 installment, or cheque).
  /// Single-installment cash rows are NOT counted — the portal pays them at its
  /// default of 1, so [total] == 0 is a perfectly successful all-single list.
  final int total;
  final Map<String, ({int? rebate, int? defaultFee})> rebates;
  final String? error;
  const InstallmentFillResult(this.saved, this.total,
      {this.rebates = const {}, this.error});

  /// True when every row that needed keying got keyed (and no error). A list
  /// with nothing to key ([total] == 0) is ok by definition.
  bool get ok => error == null && saved >= total;
  bool get allSaved => total > 0 && saved >= total;
}

/// Drives a logged-in WebView to the "Agent Inquire and Update" account list
/// (Finacle `AgentRDActSummaryAllListing`) and reads every RD account.
///
/// Robustness for a heavy legacy portal on a phone WebView:
///  - waits for the account table to actually render before reading a page,
///  - retries the "Next" click if a page stalls,
///  - detects a "Session Expired" bounce and stops with a clear error,
///  - de-duplicates by account number and stops at the "Page X of N" total.
///
/// The owner wires the WebView's onPageFinished to [notifyPageFinished].
class PortalSyncEngine {
  PortalSyncEngine(this.controller);

  final WebViewController controller;
  Completer<void>? _pageLoad;

  /// How many operations currently own the page.
  ///
  /// The portal is single-threaded from its own point of view: it mints one
  /// transaction token per navigation and treats a second post arriving before
  /// the first has rendered as a replay. Anything that navigates must therefore
  /// take this lock, and anything *optional* that navigates — the keep-alive is
  /// the only one — must decline to run while it is held.
  int _pageOwners = 0;

  /// True while a walk (or any navigating operation) owns the page.
  bool get isDriving => _pageOwners > 0;

  /// Run [body] as the sole owner of the page.
  Future<T> _drive<T>(Future<T> Function() body) async {
    _pageOwners++;
    try {
      return await body();
    } finally {
      _pageOwners--;
    }
  }

  void notifyPageFinished() {
    final c = _pageLoad;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }

  /// Wait out Finacle's "previous click was still being processed" banner.
  ///
  /// The banner is not an error: the portal honoured the FIRST click and the
  /// page underneath is the right one. It means only that we posted too fast.
  /// So the correct response is to stop clicking and let it settle — clicking
  /// again is what escalates this into a dead session.
  Future<void> _yieldIfBusy(String html) async {
    if (!PortalDom.isBusyBanner(html)) return;
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  // --- Low-level DOM reads -------------------------------------------------

  /// Serialise the current DOM. On a slow//stalled portal the JS bridge can hand
  /// back `null` or an empty string mid-navigation — retry briefly instead of
  /// letting a null bubble up as a bogus "no accounts" result.
  Future<String> currentPageHtml() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final s = _unwrap(await controller
          .runJavaScriptReturningResult('document.documentElement.outerHTML'));
      if (s.isNotEmpty && s != 'null') return s;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return '';
  }

  /// Parse just the currently displayed page (used by the recon capture tool).
  Future<List<RdAccount>> parseCurrentPage() async =>
      AgentListParser.parsePage(await currentPageHtml());

  Future<bool> _isSessionExpired() async =>
      PortalDom.sessionExpiredMarkers.any((await currentPageHtml()).contains);

  /// Which portal screen is on the WebView right now.
  Future<PortalScreen> currentScreen() async =>
      PortalDom.classify(await currentPageHtml());

  /// Detects Finacle's stale-transaction-token guard page — "Please close this
  /// window and try accessing the application in a new browser window." — shown
  /// when the portal thinks a spent/out-of-sequence token was replayed (e.g. by
  /// a browser Back/Forward). Deep Sync avoids triggering it, but we still probe
  /// for it so a poisoned session surfaces as a clear error instead of silently
  /// ending after one account.
  Future<bool> _isBlockedPage() async {
    final html = (await currentPageHtml()).toLowerCase();
    return PortalDom.blockedMarkers.every(html.contains);
  }

  /// Is the account list currently rendered? (has the table + "Page X of N").
  Future<bool> _onListPage() async {
    final html = await currentPageHtml();
    return _hasAccountTable(html);
  }

  /// Public probe so the screen can auto-start once login lands on the list.
  Future<bool> isOnListPage() => _onListPage();

  /// The agent id the PORTAL says this session belongs to, as
  /// `corpId.cxpsUserId` (e.g. `DOP.MI8472350100005`). Empty when the page is
  /// not an authenticated one.
  ///
  /// This is the identity the backend should bind, not the string the agent
  /// typed into the login box. Finacle accepted a one-character typo of it,
  /// which produced a second backend account for the same person — one phone on
  /// each — and no 1:1 rule can catch that, because the two spellings really
  /// are two different ids.
  Future<String> portalAgentId() async {
    final js = '(function(){'
        'var c=document.querySelector(${jsonEncode(PortalDom.corpIdField)});'
        'var u=document.querySelector(${jsonEncode(PortalDom.cxpsUserIdField)});'
        'if(!u||!u.value) return "";'
        'return ((c&&c.value)?c.value+".":"")+u.value;})();';
    try {
      return _unwrap(await controller.runJavaScriptReturningResult(js)).trim();
    } catch (_) {
      return '';
    }
  }

  /// True once we're inside the authenticated agent portal (Dashboard or list) —
  /// i.e. login succeeded. Detected by the authenticated menu / pagination
  /// controls, which the login page doesn't have.
  Future<bool> isAuthenticated() async {
    final js = '(function(){return document.querySelector('
        '${jsonEncode(PortalDom.authenticatedMarker)}) ? "true" : "false";})();';
    return _unwrap(await controller.runJavaScriptReturningResult(js))
        .contains('true');
  }

  static bool _hasAccountTable(String html) =>
      PortalDom.classify(html) == PortalScreen.list;

  static int totalPages(String html) {
    final m = PortalDom.pageOfRe.firstMatch(html);
    return m != null ? int.parse(m.group(2)!) : 1;
  }

  /// How many accounts the portal says the agent has, off
  /// "Displaying 1 - 10 of 480 results". 0 when the banner isn't there.
  ///
  /// Worth reading because it is an independent check on the walk: 48 pages of
  /// 10 should be 480, and if the two disagree the walk missed something the
  /// page-by-page bookkeeping did not notice.
  static int advertisedTotal(String html) {
    final m = PortalDom.displayingRe.firstMatch(html);
    return m != null ? int.parse(m.group(3)!) : 0;
  }

  /// Which page the portal says is on screen right now — the X in "Page X of N",
  /// or 0 when the label isn't there.
  ///
  /// This is the only honest answer to "did Next actually work?". The table
  /// looking right is not enough: a click the portal drops leaves the PREVIOUS
  /// page fully rendered, table and all, and the walk used to accept that as a
  /// move. Since pages are de-duplicated by account number, re-reading page 1
  /// forty-seven times adds nothing, finishes without error, and reports a
  /// COMPLETE sync holding ten accounts — which then closes the other 455.
  static int currentPage(String html) {
    final m = PortalDom.pageOfRe.firstMatch(html);
    return m != null ? int.parse(m.group(1)!) : 0;
  }

  // --- Auto-navigation -----------------------------------------------------

  /// Where the walk narrates what it is doing.
  ///
  /// Every sync defect in this file's history has been a race — a click the
  /// portal dropped, a page-finish that fired early, a screen misread — and
  /// none of them leave a trace in a stack. The single most expensive gap in
  /// diagnosing them has been having no way to see the decisions the walk took
  /// on the handset, in order, with timings.
  ///
  /// Static rather than per-instance on purpose: it can be redirected by a hot
  /// reload without rebuilding the screen that owns the engine, which is the
  /// difference between watching a live portal session and having to start one
  /// over. Silent in release.
  static void Function(String message)? trace =
      kDebugMode ? ((m) => debugPrint('[sync] $m')) : null;

  /// The last [_logCap] trace lines, kept in memory on EVERY build.
  ///
  /// `trace` above is null in release, which meant that on the only device
  /// where these failures happen, every line this file writes was computed and
  /// then dropped. The login phase narrates exactly what went wrong — the
  /// portal's own rejection text, whether a reCAPTCHA is up, how long the
  /// Keystore took — and none of it could ever be read off the handset. That
  /// gap is why this bug has cost round after round of guessing.
  ///
  /// A capped list of short strings: a full sync writes a few hundred lines, so
  /// this is tens of KB at worst, and it never touches disk unless the agent
  /// taps Share diagnostics.
  static final List<String> log = <String>[];
  static const int _logCap = 800;

  static final _traceClock = Stopwatch()..start();

  /// Record one line. Public so the screens can narrate the LOGIN phase into
  /// the same sink — every "it just sits there" report happens before the walk
  /// starts, so the walk's own tracing never sees it.
  static void note(String message) {
    final line = '+${_traceClock.elapsedMilliseconds}ms $message';
    log.add(line);
    if (log.length > _logCap) log.removeRange(0, log.length - _logCap);
    trace?.call(line);
  }

  static void _t(String message) => note(message);

  /// The most navigating clicks one walk to the list may spend.
  ///
  /// The path is exactly two clicks (Accounts, then Enquire), so four is one
  /// full retry plus slack. The ceiling exists because Finacle reads a burst of
  /// posts on one link as a replay attack and kills the session — the previous
  /// engine measured **20 clicks in 5.6 s** against a portal that dropped one
  /// click, which is very likely what was poisoning sessions in the first place.
  ///
  /// An earlier attempt at this ceiling was reverted because it charged failed
  /// *lookups* as clicks, and the Enquire link is legitimately absent until the
  /// Accounts menu has been opened. Only clicks that actually landed are
  /// counted here, and the walk now knows which screen it is on, so it never
  /// reaches for a link that cannot be there yet.
  static const _maxNavClicks = 4;

  /// How long one click is given to produce a new page.
  ///
  /// Measured on the live portal: Accounts answers in ~3.5 s, Enquire in ~17 s.
  /// Twenty-five gives the slow one real headroom without letting a swallowed
  /// click eat a whole 75 s budget on its own.
  static const _clickPatience = Duration(seconds: 25);

  /// Reach the account list from wherever login lands.
  ///
  /// Kept returning a bare bool for existing callers;
  /// [navigateToAccountListDetailed] carries the reason.
  Future<bool> navigateToAccountList({
    Duration stepTimeout = const Duration(seconds: 75),
  }) async =>
      (await navigateToAccountListDetailed(stepTimeout: stepTimeout)).reached;

  /// Reach the account list, reporting *why* if it could not.
  ///
  /// Confirmed from real captures (`recon/live/`), the path is **two** clicks
  /// and there is an empty screen in the middle of it:
  ///
  ///   `RMDashboard` --#Accounts--> `AgentAccountHomePage` --Enquire-->
  ///   `AgentRDAccountSummaryAll`
  ///
  /// `AgentAccountHomePage` has no table, no content and no rows — the old
  /// walk could not tell it apart from a failed click, so it kept re-clicking
  /// a link it had already used. Classifying the screen first is what stops
  /// that: on the dashboard only Accounts is even attempted, and the Enquire
  /// link is only reached for once it can actually exist.
  Future<NavResult> navigateToAccountListDetailed({
    Duration stepTimeout = const Duration(seconds: 75),
  }) =>
      _drive(() => _walkToList(stepTimeout));

  Future<NavResult> _walkToList(Duration stepTimeout) async {
    final deadline = DateTime.now().add(stepTimeout);
    var clicks = 0;
    // Doubling gap between clicks. The time budget is unchanged from the old
    // walk — it is spent waiting rather than hammering the link.
    var gap = const Duration(milliseconds: 600);
    var idleRounds = 0;
    var dumped = false;
    var wentBack = false;

    _t('walk: start, budget ${stepTimeout.inSeconds}s');
    while (DateTime.now().isBefore(deadline)) {
      final html = await currentPageHtml();
      final screen = PortalDom.classify(html);
      _t('walk: on ${screen.name} (${html.length} chars, clicks=$clicks)');
      // A click that navigated and left us on the same screen means the portal
      // turned it down. Ask it why, once, rather than just clicking again.
      if (clicks >= 1 && screen != PortalScreen.list && !dumped) {
        dumped = true;
        await _traceMessages('after $clicks click(s), still ${screen.name}');
      }

      switch (screen) {
        case PortalScreen.list:
          return NavResult(true, hops: clicks);
        case PortalScreen.sessionExpired:
          return NavResult(false,
              failure: NavFailure.sessionExpired, hops: clicks);
        case PortalScreen.blocked:
          return NavResult(false, failure: NavFailure.blocked, hops: clicks);
        case PortalScreen.login:
          return NavResult(false,
              failure: NavFailure.notLoggedIn, hops: clicks);
        case PortalScreen.fullList:
          // The print-preview has no menu to click — the only way off it is
          // the way we came. Without this the walk would spin here doing
          // nothing until its budget ran out.
          if (!wentBack) {
            wentBack = true;
            _t('walk: on the print-preview, going back to the listing');
            final from = await _pageSignature();
            try {
              await controller.runJavaScript('history.back();');
              await _waitForPageChange(from, const Duration(seconds: 20));
            } catch (_) {/* re-classified on the next lap */}
            continue;
          }
          break;
        case PortalScreen.dashboard:
        case PortalScreen.accountsHome:
        case PortalScreen.unknown:
          break; // keep going
      }

      // Posted too fast. The portal kept our FIRST click and is rendering it;
      // clicking again here is exactly how this turns into a dead session.
      if (PortalDom.isBusyBanner(html)) {
        _t('walk: portal says it is still busy — backing off, NOT clicking');
        await _yieldIfBusy(html);
        continue;
      }

      // On an unknown screen a load may simply still be painting. Give it the
      // wait it would have got after a click before deciding anything.
      if (screen == PortalScreen.unknown) {
        if (idleRounds++ >= 3) return NavResult(false, hops: clicks);
        await _awaitLoad(_navSlice(deadline, cap: const Duration(seconds: 8)));
        await _settle();
        continue;
      }
      idleRounds = 0;

      if (clicks >= _maxNavClicks) break;

      // Fingerprint the page BEFORE clicking. A page-finish event cannot tell
      // us whether the navigation we just started has arrived — see
      // [_waitForPageChange] — but a change in this can.
      final before = await _pageSignature();
      _pageLoad = Completer<void>();
      final moved = screen == PortalScreen.dashboard
          ? await _clickAccountsMenu()
          : await _clickEnquireLink();
      _t('walk: clicked ${screen == PortalScreen.dashboard ? "Accounts" : "Enquire"}'
          ' -> ${moved ? "landed" : "nothing to click"}');

      if (!moved) {
        // NOTHING TO CLICK IS NOT THE SAME AS NOWHERE TO GO. The Enquire link
        // leaves the DOM the instant its navigation starts, so the commonest
        // reason there is nothing to click is that the click already landed
        // and the page is on its way. Wait it out rather than declaring
        // failure over a list that is about to appear.
        await _awaitLoad(_navSlice(deadline, cap: const Duration(seconds: 8)));
        await _settle();
        _pageLoad = null;
        if (await _onListPage()) return NavResult(true, hops: clicks);
        // Nothing to click and nothing arrived — one more classify round will
        // pick up an interstitial; `idleRounds` bounds the spinning.
        if (idleRounds++ >= 3) return NavResult(false, hops: clicks);
        continue;
      }

      clicks++;
      // Wait for the page to BECOME something else, then hold still. This is
      // what stops the next loop clicking on top of an in-flight navigation —
      // which is what the four wasted clicks on the live portal actually were.
      final arrived = await _waitForPageChange(
          before, _navSlice(deadline, cap: _clickPatience));
      _pageLoad = null;
      _t('walk: page ${arrived ? "changed" : "did NOT change"} after click');
      await _settle();
      // Back off between clicks, but never past the walk's own deadline — the
      // agent is waiting, and overshooting the budget is how "it just sits
      // there" turns into a support call.
      if (clicks < _maxNavClicks) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) break;
        await Future<void>.delayed(gap < left ? gap : left);
        gap *= 2;
      }
    }

    // One last look before answering: the walk can arrive here with a load
    // still painting, and a false here becomes an error message on a screen
    // that is about to show exactly the list it says it could not open.
    await _settle();
    if (await _onListPage()) return NavResult(true, hops: clicks);
    if (await _isSessionExpired()) {
      return NavResult(false, failure: NavFailure.sessionExpired, hops: clicks);
    }
    if (await _isBlockedPage()) {
      return NavResult(false, failure: NavFailure.blocked, hops: clicks);
    }
    return NavResult(false, hops: clicks);
  }

  /// A cheap fingerprint of what the WebView is showing: URL plus document
  /// size. Two different portal screens never share both.
  Future<String> _pageSignature() async {
    const js = '(function(){return location.href + "|" + '
        'document.documentElement.outerHTML.length + "|" + '
        'document.readyState;})();';
    try {
      return _unwrap(await controller.runJavaScriptReturningResult(js));
    } catch (_) {
      return '';
    }
  }

  /// Is the document finished loading, as far as we can tell?
  ///
  /// The signature is `url|length|readyState`. A WebView that cannot answer the
  /// readyState half — an older implementation, or a test double — must not
  /// deadlock the walk, so an unreadable answer counts as finished. Being wrong
  /// that way costs one stale read; being wrong the other way costs the whole
  /// sync.
  static bool _documentFinished(String signature) {
    final parts = signature.split('|');
    if (parts.length < 3) return true; // cannot tell — do not block on it
    return parts.last == 'complete';
  }

  /// Wait until the page genuinely becomes something else.
  ///
  /// `onPageFinished` is not a reliable "the navigation you just started has
  /// arrived" signal on this portal, for two separate reasons, and the walk was
  /// trusting it for both:
  ///
  ///  * **It fires at document load**, before Finacle's deferred scripts have
  ///    built the left menu. Measured against the live portal, the walk read
  ///    `AgentAccountHomePage` at 23,393 chars where the finished page is
  ///    26,039 — it was deciding on a DOM that was ~2,600 characters short.
  ///  * **The completer can already be resolved** by an earlier navigation's
  ///    event, so `_awaitLoad` returns instantly and the caller reads the page
  ///    it was already on.
  ///
  /// Both end the same way: the walk concludes "nothing happened", clicks
  /// again, and that second click cancels the navigation the first one started.
  /// Repeat until the click ceiling — which is exactly the live trace, four
  /// clicks that each looked like they did nothing.
  ///
  /// So wait for the signature to move instead. Then let it hold still, which
  /// is the part that catches the deferred scripts.
  Future<bool> _waitForPageChange(String before, Duration timeout) async {
    final start = DateTime.now();
    final deadline = start.add(timeout);
    // There is NO reliable early signal that a navigation has begun on this
    // portal, and assuming one cost a whole debugging round. `readyState` was
    // the obvious candidate and it is wrong: these are form posts, so the old
    // document stays "complete" until the response starts arriving — and the
    // Accounts → Enquire step was measured on the live portal taking **over
    // 17 seconds** to answer. Bailing at three seconds abandoned a navigation
    // that was perfectly healthy, then clicked again and cancelled it.
    //
    // So there is no early bail. Patience is bounded by the caller's budget
    // and nothing else; a click the portal really did swallow costs one wait
    // and is then caught by the click ceiling.
    var changed = false;
    var last = before;
    var stableFor = 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final now = await _pageSignature();
      if (now.isEmpty) continue;
      if (!changed) {
        if (now != before) {
          changed = true;
          last = now;
        }
        continue;
      }
      // Changed. Now require the document to be FINISHED and to have stopped
      // growing. Both halves matter:
      //
      //  * `readyState == complete` — measured against the live portal, size
      //    alone accepted the page at 15,766 chars while it was still loading,
      //    because a big document plateaus for a moment mid-parse. Note this is
      //    the honest use of readyState: as "has it finished", never as "has it
      //    started" — see the note above on why the latter is wrong here.
      //  * two identical samples — `complete` still precedes the deferred
      //    scripts that build the left menu, which is the other half of how the
      //    walk ended up reading a DOM 2,600 characters short.
      if (!_documentFinished(now)) {
        stableFor = 0;
        last = now;
        continue;
      }
      if (now == last) {
        if (++stableFor >= 2) return true;
      } else {
        stableFor = 0;
        last = now;
      }
    }
    return changed;
  }

  /// Read back whatever the portal is *saying* on the current page.
  ///
  /// A click that navigates and lands back on the same screen means the portal
  /// refused it — and Finacle always says why, in a message block we were
  /// throwing away. Without this the walk can only report "it didn't work",
  /// which is exactly the dead end this file's history is full of.
  Future<void> _traceMessages(String why) async {
    const js = r'''
      (function(){
        function t(el){
          return el ? (el.innerText || el.textContent || '')
            .replace(/\s+/g,' ').trim() : '';
        }
        var out = {title: document.title};
        var msgs = [];
        var sels = '[role=alert], #MessageDisplay_TABLE, .orangebg, .redbg,'
          + ' .errorbg, .greenbg, span[class*="error" i], div[class*="error" i]';
        var els = document.querySelectorAll(sels);
        for (var i=0;i<els.length;i++){
          var s = t(els[i]);
          if (s && s.length > 3 && msgs.indexOf(s) === -1) msgs.push(s);
        }
        out.messages = msgs.slice(0, 6);
        var a = document.querySelector('a[name*="Enquire"], a[id*="Enquire"]');
        out.enquire = a ? {
          href: (a.getAttribute('href')||'').slice(0,60),
          cls: a.className || '',
          hasOnclick: !!a.getAttribute('onclick')
        } : null;
        out.forms = document.forms.length;
        return JSON.stringify(out);
      })();
    ''';
    try {
      final raw = _unwrap(await controller.runJavaScriptReturningResult(js));
      _t('PORTAL SAYS ($why): $raw');
    } catch (e) {
      _t('PORTAL SAYS ($why): could not read — $e');
    }
  }

  /// How long to wait for one navigation: whatever is left of the walk's
  /// budget.
  ///
  /// This used to be capped at 11 seconds a hop, inherited from the days when
  /// the wait was a page-finish event and a long one meant "stuck". Measured
  /// against the live portal, the Accounts → Enquire step alone took **over 17
  /// seconds** to render — so the cap expired mid-navigation, the walk decided
  /// nothing had happened, and clicked again, cancelling the load it had been
  /// waiting for. That is the whole defect.
  ///
  /// There is no longer anything to protect against by capping: a click the
  /// portal swallowed is failed inside three seconds by the starting-window
  /// check in [_waitForPageChange], and the caller's own deadline still bounds
  /// the total. So be patient with a navigation that is genuinely in flight.
  /// [cap] bounds a *speculative* wait — one where we are not sure a
  /// navigation was even started, so blocking for the whole budget would just
  /// be the walk hanging. After a click that actually landed, pass no cap.
  static Duration _navSlice(DateTime deadline, {Duration? cap}) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return Duration.zero;
    if (cap == null || left < cap) return left;
    return cap;
  }

  /// Click the top-level "Accounts" menu — the first of the two hops.
  Future<bool> _clickAccountsMenu() => _clickSelector(PortalDom.accountsMenu);

  /// Click "Agent Enquire & Update Screen" — by its exact name/id from the real
  /// DOM first, then by visible text. Returns true only if something was
  /// actually clicked.
  Future<bool> _clickEnquireLink() async {
    if (await _clickSelector(PortalDom.enquireLink)) return true;
    return _clickLinkByText(const [
      'agent enquire & update',
      'enquire & update',
      'enquire and update',
      'update screen',
    ]);
  }

  /// Click the first element matching a CSS selector. Returns true if one was
  /// clicked.
  ///
  /// Disabled controls are skipped rather than reported as clicked — the
  /// listing's "Previous" button is `disabled` on page 1 and matches several of
  /// the loose fallback selectors, so a click on it would be a false success.
  Future<bool> _clickSelector(String selector) async {
    final js = '''
      (function() {
        var els = document.querySelectorAll(${jsonEncode(selector)});
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          if (el.disabled) continue;
          (el.closest('a') || el).click();
          return 'true';
        }
        return 'false';
      })();
    ''';
    return _unwrap(await controller.runJavaScriptReturningResult(js))
        .contains('true');
  }

  /// Click the first element whose visible text contains one of [needles].
  ///
  /// Two things this has to get right, both learned the hard way:
  ///
  ///  * **Resolve downward, not just upward.** `querySelectorAll` returns
  ///    ancestors before descendants, so the `<td>` wrapping the Enquire link
  ///    is always examined before the link itself — and `closest('a')` only
  ///    walks *up*, so from that cell it never finds the anchor inside it. The
  ///    old version therefore clicked the table cell, which navigates nowhere,
  ///    and returned true.
  ///  * **Only a real control counts as a click.** If what we ended up on is
  ///    not an anchor, button or input, nothing navigated, and saying "true"
  ///    sends the caller off believing the page is changing when it is not.
  Future<bool> _clickLinkByText(List<String> needles) async {
    final js = '''
      (function() {
        var needles = ${jsonEncode(needles)};
        var els = Array.prototype.slice.call(
          document.querySelectorAll('a, input[type=button], input[type=submit], button, span, td'));
        for (var n = 0; n < needles.length; n++) {
          for (var i = 0; i < els.length; i++) {
            var t = (els[i].innerText || els[i].value || els[i].textContent || '')
              .trim().toLowerCase();
            if (!t || t.indexOf(needles[n]) === -1) continue;
            // Down first (a container holding the real link), then up (a label
            // inside one), then the element itself.
            var target = els[i].querySelector('a, button, input')
              || els[i].closest('a, button')
              || els[i];
            if (target.disabled) continue;
            var tag = (target.tagName || '').toLowerCase();
            if (tag !== 'a' && tag !== 'button' && tag !== 'input') continue;
            target.click();
            return 'true';
          }
        }
        return 'false';
      })();
    ''';
    return _unwrap(await controller.runJavaScriptReturningResult(js))
        .contains('true');
  }

  // --- Page walk -----------------------------------------------------------

  Future<SyncResult> syncAllPages({
    void Function(int page, int totalPages, int accounts)? onProgress,
    Duration pageTimeout = const Duration(seconds: 60),
  }) =>
      _drive(() => _syncAllPages(onProgress, pageTimeout));

  Future<SyncResult> _syncAllPages(
    void Function(int page, int totalPages, int accounts)? onProgress,
    Duration pageTimeout,
  ) async {
    // Classify once rather than re-serialising the DOM for each question. On a
    // 57 KB listing page, asked 48 times over, that is not a rounding error.
    var screen = PortalDom.classify(await currentPageHtml());
    if (screen == PortalScreen.sessionExpired) {
      return const SyncResult([],
          reachedList: false,
          error: 'The portal ended this session. Log in again, then tap Sync.',
          complete: false);
    }
    if (screen != PortalScreen.list) {
      final nav = await _walkToList(const Duration(seconds: 75));
      if (!nav.reached) {
        return SyncResult(const [],
            reachedList: false, error: nav.message, complete: false);
      }
    }

    // START AT PAGE 1. This used to read whichever page the WebView happened to
    // be showing and call it page 1 — and a sync LEAVES the list on the last
    // page (see fillDetails). So a second Sync in the same session read page 47,
    // stamped those ten accounts as #1-#10, and every short code from there on
    // was wrong and collided with the real #1-#10. `_gotoPage` no-ops when the
    // portal already says page 1, so arriving fresh costs nothing.
    if (!await _gotoPage(1, pageTimeout)) {
      // Couldn't rewind — better to sync nothing than to renumber the book from
      // the middle. `serial` is what he reads off a row to find a customer.
      return const SyncResult([],
          reachedList: true,
          error: 'Could not get back to the first page. Close this and tap '
              'Sync again.',
          complete: false);
    }

    final byAccount = <String, RdAccount>{};
    var firstHtml = await currentPageHtml();
    var total = totalPages(firstHtml);

    // FAST PATH: the portal hands over the entire listing in one document via
    // the listing's "doc" icon. Forty-seven Next clicks become one request —
    // measured, the page walk was 36 s of a 60 s sync — and the portal sees
    // forty-seven fewer posts from us, which is its own kind of safety.
    //
    // Everything below is written so that FAILING here costs only time. The
    // shortcut navigates away from the listing, so any path that does not
    // return must put us back on page 1 before the walk can run.
    final advertisedNow = advertisedTotal(firstHtml);
    final full = await _fetchFullListing(advertisedNow);
    if (full != null) {
      final parsed = AgentListParser.parse(full);
      if (!parsed.isEmpty &&
          (advertisedNow == 0 || parsed.rows >= advertisedNow)) {
        for (final r in parsed.accounts) {
          byAccount.putIfAbsent(r.accountNumber, () => r);
        }
        onProgress?.call(total, total, byAccount.length);
        _t('DONE via full listing — ${byAccount.length} accounts '
            '(${parsed.matured} matured, ${parsed.rejected} rejected, '
            'portal advertised $advertisedNow)');
        return SyncResult(_serialised(byAccount),
            rejected: parsed.rejected,
            rejectedAccounts: parsed.rejectedAccounts,
            maturedRows: parsed.maturedRows);
      }
      _t('full listing parsed short (${parsed.rows} rows) — walking instead');
    }

    // The shortcut either was not offered or did not add up. Either way we may
    // no longer be on the listing, so re-establish it from scratch rather than
    // walking pages from wherever the WebView happens to be sitting.
    if (PortalDom.classify(await currentPageHtml()) != PortalScreen.list) {
      if (!(await _walkToList(const Duration(seconds: 75))).reached) {
        return const SyncResult([],
            reachedList: false,
            error: 'Could not reopen the account list. Tap Sync again.',
            complete: false);
      }
    }
    if (!await _gotoPage(1, pageTimeout)) {
      return const SyncResult([],
          reachedList: true,
          error: 'Could not get back to the first page. Close this and tap '
              'Sync again.',
          complete: false);
    }
    firstHtml = await currentPageHtml();
    total = totalPages(firstHtml);

    // "Displaying 1 - 10 of 480 results" — the portal's own count of the book,
    // arrived at independently of the page bookkeeping. Checked at the end.
    final advertised = advertisedTotal(firstHtml);
    var walked = 0; // pages actually read — compared against `total` at the end
    var rejected = 0;
    var perPage = 10; // replaced by page one's real row count, below
    final rejectedAccounts = <String>{};
    final maturedRows = <MaturedRow>[];

    for (var page = 1; page <= total; page++) {
      // Pages after the first were already fetched and validated by
      // _clickNextAndWait — reuse that document rather than serialising the
      // same 56 KB a second time.
      var html =
          page == 1 ? firstHtml : (_validatedHtml ?? await currentPageHtml());
      _validatedHtml = null;

      // The portal is telling us it is still digesting a click. The page under
      // the banner is the one it kept, so wait and re-read rather than acting
      // on a half-rendered DOM.
      if (PortalDom.isBusyBanner(html)) {
        await _yieldIfBusy(html);
        html = await currentPageHtml();
      }

      screen = PortalDom.classify(html);
      if (screen == PortalScreen.sessionExpired) {
        return SyncResult(_serialised(byAccount, complete: false),
            reachedList: true,
            rejected: rejected,
            rejectedAccounts: rejectedAccounts,
            maturedRows: maturedRows,
            error: 'The portal ended this session at page $page of $total — '
                'kept what loaded. Log in again, then tap Sync.',
            complete: false);
      }
      if (screen == PortalScreen.blocked) {
        return SyncResult(_serialised(byAccount, complete: false),
            reachedList: true,
            rejected: rejected,
            rejectedAccounts: rejectedAccounts,
            maturedRows: maturedRows,
            error: 'The portal blocked this session at page $page of $total. '
                'Log in again, then tap Sync.',
            complete: false);
      }

      // The portal's own page label must agree with where we think we are.
      // Belt and braces beside the check in _clickNextAndWait: if the two ever
      // disagree we are reading a page twice, and a duplicate read is exactly
      // what makes a short book look like a finished one.
      final shown = currentPage(html);
      if (shown != 0 && shown != page) {
        return SyncResult(_serialised(byAccount, complete: false),
            reachedList: true,
            rejected: rejected,
            rejectedAccounts: rejectedAccounts,
            maturedRows: maturedRows,
            error: 'Sync lost its place at page $page of $total (the portal '
                'is showing page $shown). Run Sync again; nothing already on '
                'the phone was changed.',
            complete: false);
      }

      final parsed = AgentListParser.parse(html);
      _t('page $page/$total: ${parsed.accounts.length} accounts, '
          '${parsed.matured} matured, ${parsed.rejected} rejected');
      rejected += parsed.rejected;
      rejectedAccounts.addAll(parsed.rejectedAccounts);
      maturedRows.addAll(parsed.maturedRows);

      // The parser numbers rows within the page it was handed; the book's
      // numbering is that plus everything on the pages before. Taken off page
      // one's own row count rather than assumed, because being wrong here is
      // what breaks every later page-jump.
      if (page == 1) perPage = _sanePageSize(parsed.rows);
      final offset = (page - 1) * perPage;
      for (final r in parsed.accounts) {
        byAccount.putIfAbsent(r.accountNumber,
            () => r.serial > 0 ? r.copyWith(serial: offset + r.serial) : r);
      }

      // A listing page with no readable rows at all means the table did not
      // render, not that the agent has an empty page in the middle of his book.
      // Treating it as read is how a blank page silently closes ten customers.
      if (parsed.isEmpty) {
        return SyncResult(_serialised(byAccount, complete: false),
            reachedList: true,
            rejected: rejected,
            rejectedAccounts: rejectedAccounts,
            maturedRows: maturedRows,
            error: 'Page $page of $total came back empty — the portal did not '
                'finish loading it. Run Sync again.',
            complete: false);
      }

      onProgress?.call(page, total, byAccount.length);
      if (page == total) {
        walked = page;
        break;
      }

      final advance =
          await _clickNextAndWait(pageTimeout, expectPage: page + 1);
      _t('page $page -> ${page + 1}: ${advance.name}');
      if (advance != PageAdvance.moved) {
        // A stall and a poisoned session look identical from here — both leave
        // the table unrendered — so ask which it was before telling the agent
        // to do something that cannot work.
        final after = PortalDom.classify(await currentPageHtml());
        final dead = after == PortalScreen.sessionExpired ||
            after == PortalScreen.blocked ||
            after == PortalScreen.login;
        return SyncResult(_serialised(byAccount, complete: false),
            reachedList: true,
            rejected: rejected,
            rejectedAccounts: rejectedAccounts,
            maturedRows: maturedRows,
            error: dead
                ? 'The portal ended this session at page $page of $total. '
                    'Log in again, then tap Sync.'
                : 'Sync stopped at page $page of $total — only '
                    '${byAccount.length} accounts were read. Run Sync again; '
                    'nothing already on the phone was changed.',
            complete: false);
      }
      walked = page + 1;
    }

    // Belt and braces: the loop can only end early via the paths above, but a
    // future edit must not be able to reintroduce a silent short read.
    if (walked < total) {
      return SyncResult(_serialised(byAccount, complete: false),
          reachedList: true,
          rejected: rejected,
          rejectedAccounts: rejectedAccounts,
          maturedRows: maturedRows,
          error: 'Sync ended at page $walked of $total — run it again.',
          complete: false);
    }

    // Cross-check against the portal's own headline count. The page walk can
    // be internally consistent and still short — a page that rendered its
    // table but only half its rows passes every check above. `complete` is
    // what licenses closing every account we did not see, so it has to clear
    // this bar too.
    final seen = byAccount.length + rejected + maturedRows.length;
    if (advertised > 0 && seen < advertised) {
      return SyncResult(_serialised(byAccount, complete: false),
          reachedList: true,
          rejected: rejected,
          rejectedAccounts: rejectedAccounts,
          maturedRows: maturedRows,
          error: 'Sync read $seen of the $advertised accounts the portal '
              'lists. Run Sync again; nothing already on the phone was '
              'changed.',
          complete: false);
    }

    _t('walk: DONE — ${byAccount.length} accounts over $total pages '
        '(${maturedRows.length} matured, $rejected rejected, portal '
        'advertised $advertised)');
    return SyncResult(_serialised(byAccount),
        rejected: rejected,
        rejectedAccounts: rejectedAccounts,
        maturedRows: maturedRows);
  }

  /// Open the print-preview of whatever report is on screen and return its
  /// HTML, or null if there is no such link or the navigation never arrived.
  ///
  /// Every paginated Finacle report carries the same `#HREF_printPreview`
  /// anchor, and it renders the WHOLE result set in one document — the trick
  /// that turns a 48-page account walk, or a 70-page ASLAAS report, into one
  /// request.
  ///
  /// Do not click the icon: its onclick opens a popup window the WebView will
  /// not service. Navigate to its href.
  ///
  /// The caller MUST call [_leavePrintPreview] afterwards, on every path. The
  /// preview is content only — no menus, no pagination — so a session parked
  /// there can do nothing else for the rest of its life.
  Future<String?> _openPrintPreview(String what) async {
    final js = '(function(){var a=document.querySelector('
        '${jsonEncode(PortalDom.printPreviewLink)});'
        'return a && a.href ? a.href : "";})();';
    final href = _unwrap(await controller.runJavaScriptReturningResult(js));
    if (href.isEmpty || !href.startsWith('http')) {
      _t('$what: no print-preview link on this page');
      return null;
    }
    final before = await _pageSignature();
    await controller.runJavaScript('location.href=${jsonEncode(href)};');
    if (!await _waitForPageChange(before, _clickPatience)) {
      _t('$what: navigation did not arrive');
      return null;
    }
    return currentPageHtml();
  }

  /// Step back off a print preview onto the page that opened it.
  Future<void> _leavePrintPreview() async {
    final backFrom = await _pageSignature();
    try {
      await controller.runJavaScript('history.back();');
      await _waitForPageChange(backFrom, const Duration(seconds: 20));
    } catch (_) {/* the caller checks where we landed */}
  }

  /// Read the whole book from the portal's own print-preview of the listing.
  ///
  /// The listing carries a "doc" icon whose href returns EVERY account in one
  /// document — same table, same per-field element ids, no pagination. That
  /// replaces forty-seven Next clicks with a single request: measured, the page
  /// walk was 36 s of a 60 s sync, and it is also forty-seven more posts than
  /// the portal needs to see from us.
  ///
  /// Returns null when the shortcut is not available or does not add up, so the
  /// caller falls back to the page walk. Two things must hold before the result
  /// is trusted:
  ///
  ///  * the page must classify as [PortalScreen.fullList] — not a stale listing,
  ///    not an error;
  ///  * the row count must match what the listing page advertised. A truncated
  ///    export is far worse than a slow sync, because a COMPLETE sync closes
  ///    every account it did not see.
  ///
  /// Do not click the icon: its onclick opens a popup window the WebView will
  /// not service. Navigate to its href.
  Future<String?> _fetchFullListing(int expectRows) async {
    final html = await _openPrintPreview('full listing');
    if (html == null) return null;
    final screen = PortalDom.classify(html);
    if (screen != PortalScreen.fullList) {
      _t('full listing: got ${screen.name} instead — falling back');
      return null;
    }
    final rows = RegExp(r'ACCOUNT_NUMBER_ALL_ARRAY\[(\d+)\]')
        .allMatches(html)
        .map((m) => m.group(1))
        .toSet()
        .length;
    if (expectRows > 0 && rows < expectRows) {
      _t('full listing: only $rows rows, portal advertised $expectRows — '
          'falling back to the page walk rather than trusting a short read');
      return null;
    }
    _t('full listing: $rows rows in one request (${html.length} chars)');

    // Go BACK to the paginated listing before handing the data over.
    //
    // The print-preview is content only: it carries no Accounts menu, no
    // Dashboard link and no pagination (verified against the capture — zero
    // hits for all three). Leaving the WebView parked there strands the
    // session: `navigateToAccountList` has nothing to click, so Deep Sync and
    // list preparation, which both start by getting to the listing, would fail
    // for the rest of the session. The read is worthless if it costs the
    // agent everything he does next.
    await _leavePrintPreview();

    // Then walk to the listing PROPERLY, even when back() appears to have
    // landed on one.
    //
    // `history.back()` is a browser Back, and a browser Back is the documented
    // way to poison a Finacle session: it restores a page whose transaction
    // token has already been spent, and the next post against it earns the
    // "close this window and try again in a new browser window" guard (see
    // [_isBlockedPage]). The restored page classifies as a perfectly good
    // listing, so the old check could not tell the difference — it only
    // re-walked when back() had visibly failed. Everything the agent does after
    // a sync goes through this page: opening one account's details, Deep Sync,
    // ticking a list. Two clicks to mint a fresh token is nothing against
    // losing all three for the rest of the session.
    final landed = PortalDom.classify(await currentPageHtml());
    _t('full listing: back() landed on ${landed.name}; re-walking for a '
        'fresh transaction token');
    await _walkToList(const Duration(seconds: 75));
    _t('full listing: session left on '
        '${(await currentScreen()).name}');
    return html;
  }

  /// Hand over the accounts with their portal positions intact.
  ///
  /// The position itself is stamped by [AgentListParser] from the portal's own
  /// row index, and the callers above have already offset it by page. This used
  /// to renumber the accounts 1..N here instead, which is subtly but expensively
  /// wrong: maturities and rejected rows hold a position in the listing without
  /// ever reaching this map, so every account after them came out one row (or
  /// three) too early. `serial` is both the agent's short code and the index a
  /// list build jumps by — see [prepareList] — so a drift of three rows sent
  /// roughly a third of those jumps to the page BEFORE the account, and each
  /// miss fell back to a full 47-page scan.
  ///
  /// [complete] must be false when the walk stopped early. A short read only
  /// ever holds a PREFIX of the book, so its numbering is right for those
  /// accounts and leaves every account after them holding a stale number from
  /// the previous sync — two accounts answering to the same short code. Passing
  /// serial 0 instead makes `replaceAll` keep whatever each account already had,
  /// so a failed sync changes no numbering at all.
  List<RdAccount> _serialised(Map<String, RdAccount> byAccount,
      {bool complete = true}) {
    final list = byAccount.values.toList();
    if (!complete) {
      for (var i = 0; i < list.length; i++) {
        list[i] = list[i].copyWith(serial: 0);
      }
      return list;
    }
    // Belt and braces for markup this parser can only read positionally: if
    // nothing carried a position, fall back to the old 1..N numbering rather
    // than shipping a book with no short codes at all.
    if (list.every((a) => a.serial <= 0)) {
      for (var i = 0; i < list.length; i++) {
        list[i] = list[i].copyWith(serial: i + 1);
      }
    }
    return list;
  }

  // --- Per-account detail --------------------------------------------------
  // Navigating in and out of each account is the ONLY safe way to read detail
  // pages. Finacle mints a one-shot token per navigation, so fetching the links
  // out-of-band replays spent tokens and the portal kills the session
  // ("Your Session is Expired"). That costs ~2 page loads per account, so a run
  // is capped and resumes on the next sync.

  /// Jump the list to [page] (falls back to false if the control isn't found).
  ///
  /// Returns true without posting anything when the portal already says we are
  /// on [page]. That short-circuit matters more than it looks: `syncAllPages`
  /// rewinds to page 1 before every walk, and it is normally called the instant
  /// the list finishes arriving on page 1 — so the old unconditional post went
  /// out on top of a navigation that had only just settled, which is precisely
  /// the traffic shape that earns Finacle's "previous click was still being
  /// processed" banner.
  Future<bool> _gotoPage(int page, Duration timeout) async {
    final here = await currentPageHtml();
    if (currentPage(here) == page && _hasAccountTable(here)) return true;
    await _yieldIfBusy(here);

    _pageLoad = Completer<void>();
    final js = '(function(){'
        'var inp=document.querySelector(${jsonEncode(PortalDom.gotoPageField)});'
        'var btn=document.querySelector(${jsonEncode(PortalDom.gotoPageButton)});'
        'if(!inp||!btn||btn.disabled) return "false";'
        'inp.value=${jsonEncode('$page')};'
        'inp.dispatchEvent(new Event("change",{bubbles:true}));'
        'btn.click(); return "true";})();';
    final ok = _unwrap(await controller.runJavaScriptReturningResult(js));
    if (!ok.contains('true')) {
      _pageLoad = null;
      return false;
    }
    await _awaitLoad(timeout);
    await _settle();
    return _waitForTable(const Duration(seconds: 20), expectPage: page);
  }

  /// Sanity-bound a counted page size. A Finacle listing page is tens of rows,
  /// never hundreds — a count in the hundreds means we counted the whole-book
  /// print-preview, and using it would put every account on page 1.
  static int _sanePageSize(int n) => (n <= 0 || n > 50) ? 10 : n;

  /// How many account rows the portal puts on one listing page.
  ///
  /// Counted off the rendered page rather than assumed, because it is only
  /// used to turn a serial into a page number, and being wrong there sends
  /// every jump to the wrong page. Falls back to 10 (the observed value) when
  /// there are no rows to count.
  Future<int> _rowsPerPage() async {
    const js = '(function(){return String(document.querySelectorAll('
        '\'[id^="HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY"]\''
        ').length);})();';
    final n = int.tryParse(
            _unwrap(await controller.runJavaScriptReturningResult(js))
                .trim()) ??
        0;
    // Sanity-bound it. This is read off whatever page is showing, and the
    // print-preview of the whole listing renders all 479 rows in one document
    // — counting those would make `((serial-1) ~/ perPage) + 1` send every
    // jump to page 1, turning each detail fetch into a full 48-page scan.
    // A Finacle listing page is tens of rows, never hundreds.
    if (n <= 0 || n > 50) {
      if (n > 50) {
        _t('rowsPerPage: $n is not a listing page (print-preview?) — using 10');
      }
    }
    return _sanePageSize(n);
  }

  /// Account number shown in row [i] of the current list page.
  Future<String> _accountNumberAt(int i) async {
    final js = '''
      (function(){
        var as=document.querySelectorAll(
          '[id^="HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY"]');
        return as[$i] ? (as[$i].textContent||'').replace(/\\D/g,'') : '';
      })();
    ''';
    return _unwrap(await controller.runJavaScriptReturningResult(js));
  }

  /// Click the row link for [accountNumber] if it is on the current page.
  Future<bool> _clickAccountAnchor(
      String accountNumber, Duration timeout) async {
    _pageLoad = Completer<void>();
    final ok = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var t=${jsonEncode(accountNumber)};
        var as=document.querySelectorAll(
          '[id^="HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY"]');
        for(var i=0;i<as.length;i++){
          if((as[i].textContent||'').replace(/\\D/g,'')===t){
            as[i].click(); return 'true';
          }
        }
        return 'false';
      })();
    '''));
    if (!ok.contains('true')) {
      _pageLoad = null;
      return false;
    }
    await _awaitLoad(timeout);
    await _settle();
    // The JS says "I found it and called click()", which is not the same as
    // "the portal navigated". On the print-preview of the listing these are
    // <span>s, not <a>s, so the click does nothing at all — and reporting that
    // as success meant parsing the listing itself as a detail page and saving
    // whatever fell out. Still on the listing means the click went nowhere.
    if (await _onListPage()) {
      _t('detail: click on $accountNumber did not navigate');
      return false;
    }
    return true;
  }

  Future<AccountDetail?> _parseDetailAndBack(Duration timeout) async {
    AccountDetail? detail;
    try {
      detail = AgentDetailParser.parse(await currentPageHtml());
    } catch (_) {
      detail = null;
    }
    await _backToList(timeout);
    return (detail != null && detail.hasData) ? detail : null;
  }

  /// ONE-CALL bulk read of last-deposit dates.
  ///
  /// The account list itself carries no deposit date, but the portal's "View
  /// Saved Installments" report lists deposits for many accounts at once — so a
  /// single page load can cover what would otherwise be hundreds of detail
  /// visits. Uses normal navigation (fresh token), so it cannot poison the
  /// session the way fetching harvested links did.
  ///
  /// Returns `accountNumber -> latest deposit date`, empty if the report isn't
  /// available or is laid out differently than expected.
  Future<Map<String, DateTime>> fetchSavedInstallments({
    Duration timeout = const Duration(seconds: 60),
    void Function(String reason)? onDiag,
  }) async {
    if (!await _onListPage() && !await navigateToAccountList()) {
      onDiag?.call('not on the account list');
      return const {};
    }
    _pageLoad = Completer<void>();
    final clicked = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var b=document.querySelector('input[name*="VIEW_SAVED_INSTALLMENTS" i]')
          || document.querySelector('input[value*="Saved Installment" i]')
          || document.querySelector('a[name*="VIEW_SAVED_INSTALLMENTS" i]');
        if(!b || b.disabled) return 'false';
        b.click(); return 'true';
      })();
    '''));
    if (!clicked.contains('true')) {
      _pageLoad = null;
      onDiag?.call('no "View Saved Installments" button');
      return const {};
    }
    await _awaitLoad(timeout);
    await _settle();

    final html = await currentPageHtml();
    final map = SavedInstallmentsParser.parse(html);
    if (map.isEmpty) {
      onDiag?.call('report had no account+date rows (${html.length} chars)');
    }
    await _backToList(timeout);
    return map;
  }

  /// Bulk-read each account's ASLAAS number from the portal's "ASLAAS Number
  /// Report" (Accounts sidebar → ASLAAS Number Report → Search). Walks every
  /// report page and returns `accountNumber -> ASLAAS` (skipping "APPLIED" /
  /// blank). Best-effort with on-screen diagnostics; uses normal navigation so
  /// it can't poison the session.
  Future<Map<String, String>> fetchAslaasReport({
    void Function(int page, int total, int found)? onProgress,
    void Function(String reason)? onDiag,
    bool Function()? shouldStop,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    Future<bool> onReport() async =>
        (await currentPageHtml()).toLowerCase().contains('aslaas number');

    // Exact sidebar link (stable id/name from the portal DOM).
    const reportLink =
        'a[id="ASLAAS Number Report"], a[name="HREF_ASLAAS Number Report"]';

    // 1. Navigate to the report unless we're already on it.
    if (!await onReport()) {
      _pageLoad = Completer<void>();
      var clicked = await _clickSelector(reportLink);
      if (!clicked) {
        // Sidebar not shown yet — open the Accounts menu first, then the link.
        _pageLoad = Completer<void>();
        final openedMenu = await _clickSelector(
            '#Accounts, a[name="HREF_Accounts"], #Accounts a');
        if (openedMenu) {
          await _awaitLoad(const Duration(seconds: 8));
          await _settle();
        } else {
          _pageLoad = null;
        }
        _pageLoad = Completer<void>();
        clicked = await _clickSelector(reportLink);
      }
      if (!clicked) {
        _pageLoad = null;
        onDiag?.call('could not find the "ASLAAS Number Report" link');
        return const {};
      }
      await _awaitLoad(timeout);
      await _settle();
    }

    // 2. Click Search (blank filters => all accounts).
    _pageLoad = Completer<void>();
    final searched = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var b=document.querySelector('#SEARCH_ASLAAS_NUMBER')
          || document.querySelector('input[name="Action.SEARCH_ASLAAS_NUMBER"]')
          || document.querySelector('input[value="Search" i]')
          || document.querySelector('input[name*="SEARCH" i]');
        if(!b || b.disabled) return 'false';
        b.click(); return 'true';
      })();
    '''));
    if (searched.contains('true')) {
      await _awaitLoad(timeout);
      await _settle();
    } else {
      _pageLoad = null; // results may already be on screen
    }

    // 3. Read the report.
    final out = <String, String>{};
    var html = await currentPageHtml();
    if (!RegExp('aslaas number', caseSensitive: false).hasMatch(html)) {
      onDiag?.call('ASLAAS report did not open (${html.length} chars)');
      return const {};
    }
    final total = totalPages(html);
    final advertised = advertisedTotal(html);

    // FAST PATH: this report carries the same print-preview link the account
    // listing does, and it renders all ~692 rows in one document. Seventy Next
    // clicks become one request. Failing here costs only time — the page walk
    // below still runs.
    final preview = await _fetchFullAslaas(advertised);
    if (preview != null) {
      onProgress?.call(total, total, preview.numbers.length);
      _t('aslaas: DONE via print preview — ${preview.numbers.length} numbers '
          'over ${preview.rows} rows (${preview.applied} not issued yet)');
      return preview.numbers;
    }

    // The shortcut may have navigated away and stepped back, so re-read rather
    // than walking from a document captured before all that.
    html = await currentPageHtml();
    if (!RegExp('aslaas number', caseSensitive: false).hasMatch(html)) {
      onDiag?.call('lost the ASLAAS report — open it again');
      return const {};
    }

    for (var page = 1; page <= total; page++) {
      if (shouldStop?.call() ?? false) break;
      out.addAll(AslaasReportParser.parse(html));
      onProgress?.call(page, total, out.length);
      if (page >= total) break;

      _pageLoad = Completer<void>();
      final next =
          _unwrap(await controller.runJavaScriptReturningResult(_nextJs));
      if (!next.contains('true')) {
        _pageLoad = null;
        break; // no next control found — stop cleanly
      }
      await _awaitLoad(timeout);
      await _settle();
      // Wait for the report table to re-render before parsing the next page.
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        html = await currentPageHtml();
        if (RegExp('aslaas number', caseSensitive: false).hasMatch(html)) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      html = await currentPageHtml();
    }
    if (out.isEmpty) onDiag?.call('report opened but no ASLAAS rows parsed');
    return out;
  }

  /// What export/pagination controls the report on screen actually has.
  ///
  /// Diagnostic only. Two shortcut attempts have now been made on this report
  /// from a capture of a DIFFERENT report screen; this ends that by reading the
  /// real one and writing it into the trace the agent can already share.
  Future<String> _reportControls() async {
    const js = r'''
      (function(){
        function ids(sel){
          var out=[]; var els=document.querySelectorAll(sel);
          for(var i=0;i<els.length && i<12;i++){
            out.push(els[i].id||els[i].name||els[i].value||'?');
          }
          return out.join(',') || 'none';
        }
        var fmt='none';
        var sel=document.querySelector('select[name*="OUTFORMAT" i]');
        if(sel){
          var o=[];
          for(var i=0;i<sel.options.length;i++){
            o.push(sel.options[i].value+'='+sel.options[i].text);
          }
          fmt=o.join(' ');
        }
        return 'printPreview=['+ids('#HREF_printPreview, a[name="HREFprintPreview"]')
          +'] printLike=['+ids('a[id*="print" i], a[name*="print" i]')
          +'] outformat=['+fmt
          +'] download=['+ids('input[name*="DOWNLOAD" i], input[value="OK" i]')
          +'] rows='+document.querySelectorAll('tr').length;
      })();
    ''';
    try {
      return _unwrap(await controller.runJavaScriptReturningResult(js));
    } catch (e) {
      return 'probe failed: $e';
    }
  }

  /// Read the WHOLE ASLAAS report from its print preview, or null to fall back
  /// to the page walk.
  ///
  /// Validated against the report's own "Displaying 1 - 10 of 692 results"
  /// banner, and against ROWS rather than numbers: a report where a hundred
  /// accounts still read "APPLIED" yields a short map on a complete read, so
  /// checking the map size would reject a perfectly good preview — and, worse,
  /// accepting a truncated one would leave those accounts holding whatever
  /// ASLAAS they already had, printed on a list at the counter.
  Future<AslaasReport?> _fetchFullAslaas(int expectRows) async {
    final html = await _openPrintPreview('aslaas');
    if (html == null) {
      // Say what this screen DOES offer, so the next diagnostics answer the
      // question instead of raising it again. The account listing's shortcut is
      // a print-preview anchor; this report may only have the OUTFORMAT
      // download (PDF/XLS), which is a file the WebView cannot hand back.
      _t('aslaas: controls on this page -> ${await _reportControls()}');
      return null;
    }

    AslaasReport? out;
    if (!RegExp('aslaas number', caseSensitive: false).hasMatch(html)) {
      _t('aslaas: print preview is not the report — falling back');
    } else {
      final read = AslaasReportParser.read(html);
      if (expectRows > 0 && read.rows < expectRows) {
        _t('aslaas: preview held ${read.rows} rows, portal advertised '
            '$expectRows — falling back to the page walk');
      } else if (read.rows == 0) {
        _t('aslaas: preview parsed no rows — falling back');
      } else {
        out = read;
      }
    }

    // Off the preview either way: it has no menus, so staying would strand the
    // session for everything the agent does next.
    await _leavePrintPreview();
    if (!await isAuthenticated()) {
      _t('aslaas: back() did not land on an authenticated page');
    }
    return out;
  }

  /// Fill exact detail for accounts in [needed], capped at [maxPerRun] so a
  /// sync never turns into a long wait. [startPage] skips straight past the
  /// accounts already done. Saves as it goes; the next sync resumes.
  Future<int> fillDetails({
    required Set<String> needed,
    required Future<void> Function(AccountDetail) onAccount,
    void Function(int done, int target)? onProgress,
    void Function(String reason)? onDiag,
    bool Function()? shouldStop,
    int maxPerRun = 60,
    int startPage = 1,
    Duration pageTimeout = const Duration(seconds: 60),
  }) async {
    if (needed.isEmpty) return 0;
    if (!await _onListPage() && !await navigateToAccountList()) {
      onDiag?.call('could not open the account list');
      return 0;
    }
    final pages = totalPages(await currentPageHtml());
    final target = math.min(maxPerRun, needed.length);
    var done = 0;

    // The list sync leaves us on the LAST page — without this the walk starts
    // at the end, finds no "Next", and gives up after one page.
    final from = startPage.clamp(1, pages);
    if (!await _gotoPage(from, pageTimeout)) {
      onDiag?.call('could not jump to page $from');
      return 0;
    }

    for (var page = from; page <= pages; page++) {
      final rows = await _detailLinkCount();
      for (var i = 0; i < rows; i++) {
        if (shouldStop?.call() ?? false) return done;
        if (done >= target) return done; // bounded — rest continues next sync
        final acc = await _accountNumberAt(i);
        if (acc.isEmpty || !needed.contains(acc)) continue;
        final detail = await _openDetailAndBack(i, pageTimeout);
        if (detail != null && detail.hasData) {
          await onAccount(detail);
          done++;
          onProgress?.call(done, target);
        }
        if (await _isSessionExpired()) {
          onDiag?.call('session expired after $done');
          return done;
        }
        if (await _isBlockedPage()) {
          onDiag?.call('portal blocked navigation after $done');
          return done;
        }
      }
      if (page == pages) break;
      if (shouldStop?.call() ?? false) return done;
      final advance = await _clickNextAndWait(pageTimeout);
      if (advance == PageAdvance.stalled) {
        onDiag?.call('page $page of $pages stopped loading after $done');
        break;
      }
      if (advance == PageAdvance.lastPage) break;
    }
    return done;
  }

  /// Pull ONE account's exact detail on demand. [serialHint] turns a 47-page
  /// scan into a single hop.
  ///
  /// [onDiag] carries the REASON it failed. Without it every failure — a spent
  /// session, the portal's stale-token guard, a jump that would not land, an
  /// account genuinely no longer in the book — came back as the same bare null,
  /// and the agent was told "could not read that account" while the real answer
  /// was "log in again".
  Future<AccountDetail?> fetchAccountDetail({
    required String accountNumber,
    int? serialHint,
    void Function(String message)? onProgress,
    void Function(String reason)? onDiag,
    Duration pageTimeout = const Duration(seconds: 60),
  }) async {
    /// The two ways this session can already be dead. Worth asking before and
    /// after a click, because both render as "the account was not found".
    Future<String?> deadSession() async {
      if (await _isSessionExpired()) {
        return 'The portal ended this session. Log in again, then try once '
            'more.';
      }
      if (await _isBlockedPage()) {
        return 'The portal blocked this session. Close this, log in again, '
            'then try once more.';
      }
      return null;
    }

    final dead = await deadSession();
    if (dead != null) {
      onDiag?.call(dead);
      return null;
    }
    if (!await _onListPage() && !await navigateToAccountList()) {
      onDiag?.call(await deadSession() ?? 'Could not open the account list.');
      return null;
    }
    final total = totalPages(await currentPageHtml());

    if (serialHint != null && serialHint > 0) {
      // Rows per page comes from the page itself. It was hardcoded to 10, so a
      // deployment that shows any other page size sent every jump to the wrong
      // page — and the fallback for a missed jump is a full 47-page scan.
      final perPage = await _rowsPerPage();
      final page = ((serialHint - 1) ~/ perPage) + 1;
      if (page >= 1 && page <= total) {
        onProgress?.call('Opening page $page…');
        await _gotoPage(page, pageTimeout);
      }
      if (await _clickAccountAnchor(accountNumber, pageTimeout)) {
        onProgress?.call('Reading account details…');
        return _parseDetailAndBack(pageTimeout);
      }
      final dead = await deadSession();
      if (dead != null) {
        onDiag?.call(dead);
        return null;
      }
      // Rewind before scanning. This used to ignore the result, and a rewind
      // that silently failed left the scan starting from whatever page the
      // hint landed on — clicking Next from the middle of the book, so every
      // page before it was unreachable and the account "did not exist".
      if (!await _gotoPage(1, pageTimeout)) {
        onDiag?.call('Could not get back to the first page. Try again.');
        return null;
      }
    }

    for (var page = 1; page <= total; page++) {
      onProgress?.call('Searching page $page of $total…');
      if (await _clickAccountAnchor(accountNumber, pageTimeout)) {
        onProgress?.call('Reading account details…');
        return _parseDetailAndBack(pageTimeout);
      }
      final dead = await deadSession();
      if (dead != null) {
        onDiag?.call(dead);
        return null;
      }
      if (page == total) break;
      if (await _clickNextAndWait(pageTimeout) != PageAdvance.moved) {
        onDiag?.call('The portal stopped turning pages at $page of $total.');
        return null;
      }
    }
    onDiag?.call('That account is not on the portal\'s list any more.');
    return null;
  }

  // --- Bulk list preparation (mode + cross-page selection + Save) -----------
  // Automates the tedious part of the DOP "list" flow: pick the payment mode,
  // tick this lot's accounts (which are scattered across the 47 pages), and
  // click Save. Save only PREPARES the list — it does not pay. The agent then
  // enters installments and "Pay All" on the portal manually.

  /// Select the payment mode radio: 'C' cash, 'DC' DOP cheque, 'NDC' non-DOP.
  Future<bool> selectPayMode(String mode) async {
    final js = '''
      (function(){
        var r=document.querySelector(
          'input[name*="PAY_MODE_SELECTED_FOR_TRN"][value=${jsonEncode(mode)}]');
        if(!r) return 'false';
        if(!r.checked){ r.click(); }
        r.dispatchEvent(new Event('change',{bubbles:true}));
        return 'true';
      })();
    ''';
    return _unwrap(await controller.runJavaScriptReturningResult(js))
        .contains('true');
  }

  /// Tick the checkboxes on the current page whose account number is in
  /// [targets]. Returns the account numbers matched on this page.
  Future<List<String>> _selectMatchingOnPage(Set<String> targets) async {
    final js = '''
      (function(){
        var targets = ${jsonEncode(targets.toList())};
        var out=[];
        var anchors=document.querySelectorAll(
          '[id^="HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY"]');
        for(var i=0;i<anchors.length;i++){
          var num=(anchors[i].textContent||'').replace(/\\D/g,'');
          if(targets.indexOf(num)===-1) continue;
          var m=anchors[i].id.match(/\\[(\\d+)\\]/);
          if(!m) continue;
          var cb=document.querySelector(
            'input[name="CustomAgentRDAccountFG.SELECT_INDEX_ARRAY['+m[1]+']"]');
          if(cb){ if(!cb.checked){ cb.click(); } out.push(num); }
        }
        return JSON.stringify(out);
      })();
    ''';
    final raw = _unwrap(await controller.runJavaScriptReturningResult(js));
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// Click the portal's Save (Action.SAVE_ACCOUNTS) and wait for the reload.
  Future<bool> saveSelection(Duration timeout) async {
    _pageLoad = Completer<void>();
    final clicked = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var b=document.querySelector('input[name="Action.SAVE_ACCOUNTS"]')
          || document.querySelector('input[value="Save"]');
        if(!b || b.disabled) return 'false';
        b.click(); return 'true';
      })();
    '''));
    if (!clicked.contains('true')) {
      _pageLoad = null;
      return false;
    }
    await _awaitLoad(timeout);
    await _settle();
    return true;
  }

  /// Tick the lot's accounts across the portal pages (mode set on each page so
  /// it survives the reloads), then Save.
  ///
  /// FAST PATH: when [serialByAccount] is given (each account's 1-based row
  /// position in the listing, from the last sync), we jump straight to the page
  /// holding each account instead of scanning all ~47 pages. A full sequential
  /// scan still runs for anything the fast path didn't find (unknown serial, or
  /// the portal list changed since sync), so an account is never silently
  /// skipped — but it costs the whole walk, so the index earning its keep
  /// depends on those serials being TRUE row positions. See [_serialised].
  /// Selections persist server-side across navigation, so order doesn't matter.
  Future<ListPrepResult> prepareList({
    required Set<String> accountNumbers,
    required String mode,
    Map<String, int>? serialByAccount,
    void Function(int page, int total, int selected)? onProgress,
    Duration pageTimeout = const Duration(seconds: 60),
  }) async {
    if (accountNumbers.isEmpty) {
      return const ListPrepResult({}, 0, error: 'This lot has no accounts.');
    }
    if (await _isSessionExpired()) {
      return ListPrepResult(const {}, accountNumbers.length,
          error: 'Session expired — please log in again.');
    }
    if (!await _onListPage() && !await navigateToAccountList()) {
      return ListPrepResult(const {}, accountNumbers.length,
          error: 'Could not open the account list.');
    }

    final total = totalPages(await currentPageHtml());
    final found = <String>{};

    // --- Fast path: direct page jumps using the recorded serials -----------
    if (serialByAccount != null) {
      // Counted off the listing in front of us, not assumed: the serial->page
      // arithmetic is only as right as this number.
      final perPage = await _rowsPerPage();
      final byPage = <int, Set<String>>{};
      for (final a in accountNumbers) {
        final s = serialByAccount[a] ?? 0;
        if (s <= 0) continue;
        final page = (((s - 1) ~/ perPage) + 1).clamp(1, total);
        byPage.putIfAbsent(page, () => <String>{}).add(a);
      }
      for (final page in byPage.keys.toList()..sort()) {
        if (!await _gotoPage(page, pageTimeout)) break;
        await selectPayMode(mode);
        final hit = await _selectMatchingOnPage(byPage[page]!);
        found.addAll(hit);
        _t('prepare: page $page held ${hit.length}/${byPage[page]!.length} '
            'of the accounts indexed to it');
        onProgress?.call(page, total, found.length);
        if (await _isSessionExpired()) {
          return ListPrepResult(found, accountNumbers.length,
              error: 'Session expired — selected ${found.length}.');
        }
      }
    }

    // --- Second chance: halve the listing instead of walking it -------------
    // The index is only as fresh as the last sync. One account opened since
    // then shifts everyone after it, and every shifted account used to cost the
    // full walk. Six jumps settle a 48-page book instead.
    var remaining = accountNumbers.difference(found);
    if (remaining.isNotEmpty) {
      final probed = await _probeSortedListing(
          remaining, total, mode, pageTimeout, onProgress, found.length);
      found.addAll(probed);
      remaining = accountNumbers.difference(found);
    }

    // --- Correctness net: sequential scan for anything still missing --------
    if (remaining.isNotEmpty) {
      await _gotoPage(
          1, pageTimeout); // reset to the top (no-op if already there)
      for (var page = 1; page <= total; page++) {
        await selectPayMode(mode);
        found.addAll(await _selectMatchingOnPage(remaining));
        onProgress?.call(page, total, found.length);
        if (found.length >= accountNumbers.length) break;
        if (page == total) break;
        if (await _clickNextAndWait(pageTimeout) != PageAdvance.moved) break;
        if (await _isSessionExpired()) {
          return ListPrepResult(found, accountNumbers.length,
              error:
                  'Session expired at page $page — selected ${found.length}.');
        }
      }
    }

    await selectPayMode(mode);
    final saved = await saveSelection(pageTimeout);
    return ListPrepResult(found, accountNumbers.length,
        saved: saved,
        error: saved ? null : 'Could not click Save on the portal.');
  }

  /// Find [targets] by halving the listing rather than walking it.
  ///
  /// The portal renders the book in ascending account-number order, so a page's
  /// first and last numbers say whether a target can possibly be on it — which
  /// makes this an ordinary binary search: ~6 jumps for a 48-page book against
  /// 47 for the scan.
  ///
  /// Sortedness is CHECKED on every page read, never assumed. The listing's
  /// column headers are sort links, and an agent who has clicked one leaves the
  /// book in an order this search would follow straight to the wrong page. The
  /// first page that comes back out of order ends the probe and hands the work
  /// back to the sequential scan, which needs no such assumption.
  ///
  /// Returns the accounts it ticked. Anything it could not place is left to the
  /// caller's scan — an account is never written off as absent here.
  Future<Set<String>> _probeSortedListing(
    Set<String> targets,
    int total,
    String mode,
    Duration pageTimeout,
    void Function(int page, int total, int selected)? onProgress,
    int alreadySelected,
  ) async {
    final found = <String>{};
    if (total <= 1) return found;

    // Pages already read, so overlapping searches share their upper levels.
    final seen = <int, List<String>>{};
    // Past this, the walk is the cheaper way to finish — and a probe that has
    // read half the book has ticked everything it passed on the way.
    final budget = (total / 2).ceil();
    var sorted = true;

    /// Read page [page] (jumping only when we are not already there) and tick
    /// anything still wanted that turns out to be on it.
    Future<List<String>?> visit(int page) async {
      var nums = seen[page];
      if (nums == null) {
        if (seen.length >= budget) return null;
        if (!await _gotoPage(page, pageTimeout)) return null;
        nums = await _accountNumbersOnPage();
        if (nums.isEmpty) return null;
        if (!_isAscending(nums)) {
          _t('probe: page $page is not in account-number order — '
              'leaving it to the scan');
          sorted = false;
          return null;
        }
        seen[page] = nums;
      }
      final want = targets.difference(found).intersection(nums.toSet());
      if (want.isNotEmpty) {
        if (!await _gotoPage(page, pageTimeout)) return null;
        await selectPayMode(mode);
        found.addAll(await _selectMatchingOnPage(want));
        onProgress?.call(page, total, alreadySelected + found.length);
      }
      return nums;
    }

    for (final target in targets) {
      if (found.contains(target)) continue;
      var lo = 1;
      var hi = total;
      while (lo <= hi) {
        final mid = lo + ((hi - lo) ~/ 2);
        final nums = await visit(mid);
        if (nums == null) {
          if (!sorted) return found; // out of order — the scan takes over
          break; // out of budget, or the jump failed: try the scan
        }
        if (found.contains(target)) break;
        if (_compareAccounts(target, nums.first) < 0) {
          hi = mid - 1;
        } else if (_compareAccounts(target, nums.last) > 0) {
          lo = mid + 1;
        } else {
          // In this page's range but not on it — closed since the last sync,
          // most likely. Say so and let the scan have the last word.
          _t('probe: $target belongs on page $mid but is not there');
          break;
        }
      }
      if (!sorted) break;
    }
    _t('probe: read ${seen.length} pages, ticked ${found.length} of '
        '${targets.length}');
    return found;
  }

  /// The account numbers rendered on the current page, in row order.
  Future<List<String>> _accountNumbersOnPage() async {
    const js = '(function(){var as=document.querySelectorAll('
        '\'[id^="HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY"]\');'
        'var out=[];'
        'for(var i=0;i<as.length;i++){'
        'out.push((as[i].textContent||"").replace(/\\D/g,""));}'
        'return JSON.stringify(out);})();';
    try {
      final raw = _unwrap(await controller.runJavaScriptReturningResult(js));
      return (jsonDecode(raw) as List)
          .cast<String>()
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Order two account numbers the way the PORTAL orders them: as text.
  ///
  /// Not numerically, and not by length first. The live book is not all one
  /// width — 468 twelve-digit accounts and 11 ten-digit ones — and the portal
  /// sorts the short ones AFTER the long ones (`020234825906` then
  /// `3766788625`), because that is where plain string order puts them. Any
  /// cleverer comparison disagrees with the page in front of us, which would
  /// make [_isAscending] declare a perfectly normal book unsorted and switch
  /// the probe off for the accounts most likely to need it.
  static int _compareAccounts(String a, String b) => a.compareTo(b);

  static bool _isAscending(List<String> nums) {
    for (var i = 1; i < nums.length; i++) {
      if (_compareAccounts(nums[i - 1], nums[i]) >= 0) return false;
    }
    return true;
  }

  // --- Installment entry (step 6) ------------------------------------------
  // After prepareList() Saves, the portal shows the "selected accounts" screen.
  // For each row we: select it, key the installment count (+ cheque fields),
  // click "Get Rebate & Default Fee", then Save — so its Modified flag flips to
  // YES. This ONLY keys + saves records; it never pays. Money (Pay All) stays a
  // deliberate, agent-tapped action, and the app just reads the reference after.
  //
  // Built against a captured static page and NOT yet verified against the live
  // portal — the first real run must be watched on-device.

  /// Per-account cheque details for DOP / Non-DOP cheque modes.
  /// Selectors (installment screen, form `CustomAgentRDAccountFG`):
  ///   row radio        input[name="…SELECTED_INDEX"][value=i]
  ///   installments     input[name="…RD_INSTALLMENT_NO"]
  ///   cheque no.       input[name="…RD_CHEQUE_NO"]
  ///   bank a/c on chq  input[name="…RD_ACCOUNT_NUMBER_FOR_PAYMENT"]
  ///   bank name        input[name="…BANK_NAME_RDI"]
  ///   rebate/default   Action.CALCULATE_REBATE  ·  save row: Action.ADD_TO_LIST
  ///   per-row display  #HREF_…ACCOUNT_NUMBER_ARRAY[i] / …MODIFIED_ARRAY[i]

  /// Are we on the selected-accounts / installment-entry screen?
  Future<bool> onInstallmentScreen() async {
    final n = await _installmentRowCount();
    return n > 0;
  }

  Future<int> _installmentRowCount() async {
    final r = await controller.runJavaScriptReturningResult(
        "document.querySelectorAll('input[name=\"CustomAgentRDAccountFG.SELECTED_INDEX\"]').length");
    return int.tryParse(_unwrap(r).replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  Future<String> _installmentRowAccount(int i) async {
    final js = '''
      (function(){
        var el=document.querySelector('[id*="ACCOUNT_NUMBER_ARRAY[$i]"]');
        return el ? (el.textContent||'').replace(/\\D/g,'') : '';
      })();
    ''';
    return _unwrap(await controller.runJavaScriptReturningResult(js));
  }

  Future<void> _selectInstallmentRow(int i, Duration timeout) async {
    _pageLoad = Completer<void>();
    final ok = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var r=document.querySelector(
          'input[name="CustomAgentRDAccountFG.SELECTED_INDEX"][value="$i"]');
        if(!r) return 'false';
        if(!r.checked){ r.click(); }
        r.dispatchEvent(new Event('change',{bubbles:true}));
        return 'true';
      })();
    '''));
    // Selecting a row may or may not round-trip; wait briefly either way.
    if (ok.contains('true')) {
      await _awaitLoad(const Duration(seconds: 8));
    } else {
      _pageLoad = null;
    }
    await _settle();
  }

  Future<void> _fillInstallmentFields(
      int installments, ChequeInfo? cheque) async {
    final chq = cheque == null
        ? ''
        : '''
        set('CustomAgentRDAccountFG.RD_CHEQUE_NO', ${jsonEncode(cheque.chequeNo)});
        set('CustomAgentRDAccountFG.RD_ACCOUNT_NUMBER_FOR_PAYMENT', ${jsonEncode(cheque.bankAccount)});
        set('CustomAgentRDAccountFG.BANK_NAME_RDI', ${jsonEncode(cheque.bankName)});
      ''';
    await controller.runJavaScript('''
      (function(){
        function set(name,val){
          var el=document.querySelector('input[name="'+name+'"]');
          if(!el) return;
          el.value=val;
          ['input','change','keyup','blur'].forEach(function(t){
            el.dispatchEvent(new Event(t,{bubbles:true}));});
        }
        set('CustomAgentRDAccountFG.RD_INSTALLMENT_NO', '${installments.clamp(1, 999)}');
        $chq
      })();
    ''');
  }

  /// Click a Finacle Action.* submit and wait for the reload.
  Future<bool> _clickActionAndWait(String actionName, Duration timeout) async {
    _pageLoad = Completer<void>();
    final clicked = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var b=document.querySelector('input[name=${jsonEncode(actionName)}]');
        if(!b || b.disabled) return 'false';
        b.click(); return 'true';
      })();
    '''));
    if (!clicked.contains('true')) {
      _pageLoad = null;
      return false;
    }
    await _awaitLoad(timeout);
    await _settle();
    return true;
  }

  /// The set of account numbers currently listed on the installment screen —
  /// for verifying (before paying) that exactly the list's accounts are there.
  Future<Set<String>> installmentScreenAccounts() async {
    const js = '''
      (function(){
        var out=[];
        var accs=document.querySelectorAll('[id*="ACCOUNT_NUMBER_ARRAY["]');
        for(var i=0;i<accs.length;i++){
          var num=(accs[i].textContent||'').replace(/\\D/g,'');
          if(num) out.push(num);
        }
        return JSON.stringify(out);
      })();
    ''';
    final raw = _unwrap(await controller.runJavaScriptReturningResult(js));
    try {
      return (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {
      return const {};
    }
  }

  /// Read every row's ASLAAS number off the installment screen as
  /// `accountNumber -> aslaas`. The portal stores a DIFFERENT ASLAAS per
  /// account (`ASLAAS_NO_ARRAY[i]`, a read-only column maintained under "Update
  /// ASLAAS Number"), so this is the authoritative source — the app used to
  /// print one agency-wide number on every account of a list, which was wrong.
  /// Rows are paired by array index, so reordering can't cross-assign them.
  /// Returns {} when not on that screen or the column is absent.
  Future<Map<String, String>> readAslaasNumbers() async {
    const js = '''
      (function(){
        var out={};
        var accs=document.querySelectorAll('[id*="ACCOUNT_NUMBER_ARRAY["]');
        for(var i=0;i<accs.length;i++){
          var m=accs[i].id.match(/\\[(\\d+)\\]/); if(!m) continue;
          var num=(accs[i].textContent||'').replace(/\\D/g,'');
          if(!num) continue;
          var a=document.querySelector('[id*="ASLAAS_NO_ARRAY['+m[1]+']"]');
          if(!a) continue;
          var val=(a.textContent||'').trim();
          if(val) out[num]=val;
        }
        return JSON.stringify(out);
      })();
    ''';
    final raw = _unwrap(await controller.runJavaScriptReturningResult(js));
    try {
      return (jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(k as String, (v as String).trim()));
    } catch (_) {
      return const {};
    }
  }

  /// The portal array index of the row showing [account], or -1.
  Future<int> _rowIndexOfAccount(String account) async {
    final js = '''
      (function(){
        var want=${jsonEncode(account)};
        var accs=document.querySelectorAll('[id*="ACCOUNT_NUMBER_ARRAY["]');
        for(var i=0;i<accs.length;i++){
          var m=accs[i].id.match(/\\[(\\d+)\\]/); if(!m) continue;
          if((accs[i].textContent||'').replace(/\\D/g,'')===want) return m[1];
        }
        return '-1';
      })();
    ''';
    return int.tryParse(
            _unwrap(await controller.runJavaScriptReturningResult(js))) ??
        -1;
  }

  /// The portal array index of the first row whose account is in [targets] and
  /// is NOT yet Modified=YES, or -1 if all targets are done. Reading the account
  /// off the row each time means row reordering after a Save can never misalign
  /// an installment onto the wrong customer.
  Future<int> _firstUnmodifiedTargetRow(Set<String> targets) async {
    final js = '''
      (function(){
        var targets=${jsonEncode(targets.toList())};
        var accs=document.querySelectorAll('[id*="ACCOUNT_NUMBER_ARRAY["]');
        for(var i=0;i<accs.length;i++){
          var m=accs[i].id.match(/\\[(\\d+)\\]/); if(!m) continue;
          var n=m[1];
          var num=(accs[i].textContent||'').replace(/\\D/g,'');
          if(targets.indexOf(num)===-1) continue;
          var mod=document.querySelector('[id*="MODIFIED_ARRAY['+n+']"]');
          var yes=mod && (mod.textContent||'').trim().toUpperCase()==='YES';
          if(!yes) return n;
        }
        return '-1';
      })();
    ''';
    return int.tryParse(
            _unwrap(await controller.runJavaScriptReturningResult(js))) ??
        -1;
  }

  /// How many of [targets] are now Modified=YES (paid-ready).
  Future<int> _countModifiedTargets(Set<String> targets) async {
    final js = '''
      (function(){
        var targets=${jsonEncode(targets.toList())};
        var accs=document.querySelectorAll('[id*="ACCOUNT_NUMBER_ARRAY["]');
        var c=0;
        for(var i=0;i<accs.length;i++){
          var m=accs[i].id.match(/\\[(\\d+)\\]/); if(!m) continue;
          var n=m[1];
          var num=(accs[i].textContent||'').replace(/\\D/g,'');
          if(targets.indexOf(num)===-1) continue;
          var mod=document.querySelector('[id*="MODIFIED_ARRAY['+n+']"]');
          if(mod && (mod.textContent||'').trim().toUpperCase()==='YES') c++;
        }
        return String(c);
      })();
    ''';
    return int.tryParse(
            _unwrap(await controller.runJavaScriptReturningResult(js))) ??
        0;
  }

  /// Prepare the installment screen for payment: key EVERY row on the list with
  /// Get-Rebate-&-Default + Save, so each becomes Modified=YES. NEVER pays.
  ///
  /// It used to key only the rows that differ from the portal's default of one
  /// cash installment — advance deposits (>1) and cheque rows — on the grounds
  /// that "Pay All Saved Installments" handles the rest as-is. That skipped
  /// `Action.CALCULATE_REBATE` for every ordinary row, and that click is the
  /// ONLY place the default fee exists: the grid's `RD_DEFAUT_FEE_ARRAY[i]`
  /// reads 0.00 on an unkeyed row (verified against
  /// `recon/portal_02_installment_entry.html`, every row MODIFIED=NO). So a
  /// late customer paying one installment printed a blank fee and, because
  /// [LotItem.netAmount] reads a null fee as zero, his row AND the list total
  /// came out short of what the post office actually charged. A list holding
  /// one advance payer showed the fee on that row and nowhere else, which is
  /// exactly how this was noticed.
  ///
  /// Keying every row costs more page loads — a list is capped at 9 accounts —
  /// and buys a printed list that agrees with the receipt.
  ///
  /// Robust to row reordering: it repeatedly finds the next un-keyed target
  /// row, reads THAT row's account off the page, and keys that account's own
  /// installment — so a count can't land on the wrong customer.
  /// [InstallmentFillResult.total] is now the whole list.
  Future<InstallmentFillResult> enterInstallments({
    required Map<String, int> installmentsByAccount,
    Map<String, ChequeInfo>? chequeByAccount,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldStop,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!await onInstallmentScreen()) {
      return const InstallmentFillResult(0, 0,
          error: 'Not on the installment screen — run Prepare + Save first.');
    }
    // Every account on the list, including the plain single-installment cash
    // rows. They are the ones whose default fee was never asked for.
    final targets = installmentsByAccount.keys.toSet();
    final rebates = <String, ({int? rebate, int? defaultFee})>{};
    if (targets.isEmpty) {
      return const InstallmentFillResult(0, 0);
    }
    onProgress?.call(0, targets.length);

    final maxIterations = targets.length * 3 + 5; // guard against a stuck loop
    var guard = 0;

    while (guard++ < maxIterations) {
      if (shouldStop?.call() ?? false) break;
      final idx = await _firstUnmodifiedTargetRow(targets);
      if (idx < 0) break; // all targets are Modified=YES — done
      final acc = await _installmentRowAccount(idx);
      if (acc.isEmpty) break; // shouldn't happen; stop rather than mis-key
      await _selectInstallmentRow(idx, timeout);
      await _fillInstallmentFields(
          installmentsByAccount[acc] ?? 1, chequeByAccount?[acc]);
      await _clickActionAndWait('Action.CALCULATE_REBATE', timeout);
      // READ ORDER MATTERS, and getting it wrong is why every report said 0.00.
      //
      // The portal keeps these in two places. CALCULATE_REBATE fills the
      // SELECTED ROW's fields (…REBATE / …DEFAULT_FEE, blank until then). The
      // grid row (…RD_REBATE_ARRAY[i]) is only written when the row is added to
      // the list. We used to read the grid straight after calculating — before
      // anything had written to it — so we captured the stale 0.00 sitting
      // there from page load, every single time.
      var reb = await _numField('CustomAgentRDAccountFG.REBATE');
      var def = await _numField('CustomAgentRDAccountFG.DEFAULT_FEE');

      await _clickActionAndWait('Action.ADD_TO_LIST', timeout);

      // Now the grid row exists — use it for whatever the selected-row fields
      // did not give us. Check the row still belongs to this account first:
      // adding to the list re-renders the grid, and every other read in this
      // file re-reads the account off the row for exactly that reason. A fee
      // copied off a neighbour's row is worse than a blank one, because it
      // prints as a fact.
      if (reb == null || def == null) {
        final row = await _installmentRowAccount(idx) == acc
            ? idx
            : await _rowIndexOfAccount(acc);
        if (row >= 0) {
          reb ??= await _rowNumArray('RD_REBATE_ARRAY', row);
          def ??= await _rowNumArray('RD_DEFAUT_FEE_ARRAY', row);
        }
      }

      // Record only when the portal actually answered. An entry of (null, null)
      // would overwrite good figures with blanks on a re-submit.
      if (reb != null || def != null) {
        rebates[acc] = (rebate: reb, defaultFee: def);
      }
      onProgress?.call(await _countModifiedTargets(targets), targets.length);
      if (await _isSessionExpired()) {
        return InstallmentFillResult(
            await _countModifiedTargets(targets), targets.length,
            rebates: rebates, error: 'Session expired.');
      }
    }
    final saved = await _countModifiedTargets(targets);
    return InstallmentFillResult(saved, targets.length, rebates: rebates);
  }

  /// Read one rupee figure out of a Finacle per-row array field.
  ///
  /// Returns null when the field is not on the page — which is NOT the same as
  /// zero, and used to be reported as zero. That single conflation is why every
  /// report printed "0.00" for rebate: the value was never found, and a hard 0
  /// was stored and printed as though the portal had said so.
  ///
  /// Reads `.value` before `textContent`: these are <input> elements, and an
  /// input's textContent is always empty, so the old code took the
  /// nothing-found path every single time.
  ///
  /// Parses as a DECIMAL. The old code stripped every non-digit, which turned
  /// "400.00" into 40000 — so on the rare path where it did find a value, a
  /// ₹400 rebate would have printed as ₹40,000.
  /// The SELECTED row's figure, which `Action.CALCULATE_REBATE` fills in.
  Future<int?> _numField(String idFragment) => _numFrom(idFragment);

  Future<int?> _rowNumArray(String array, int i) => _numFrom('$array[$i]');

  Future<int?> _numFrom(String idFragment) async {
    final js = '''
      (function(){
        var el=document.querySelector('[id*="$idFragment"]')
            || document.querySelector('[name*="$idFragment"]');
        if(!el) return '';
        var v = (el.value !== undefined && el.value !== null && el.value !== '')
              ? el.value : (el.textContent || '');
        return String(v).trim();
      })();
    ''';
    final raw =
        _unwrap(await controller.runJavaScriptReturningResult(js)).trim();
    if (raw.isEmpty) return null;
    // "1,400.50" -> 1400.5 -> 1400. Commas are thousands separators; the dot is
    // a decimal point. Rupees are what the report prints.
    final cleaned = raw.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;
    final d = double.tryParse(cleaned);
    return d?.round();
  }

  /// Read the reference (C…/DC…/NDC… + digits) off the current portal page.
  Future<String?> readReferenceIfPresent() async =>
      parseReference(await currentPageHtml());

  /// Click "Pay All Saved Installments" — this COMMITS the payment on the portal
  /// and cannot be undone — then read back the generated reference. The caller
  /// MUST confirm the amount with the agent before calling this. Returns the
  /// reference, or null if the click failed / no reference appeared (e.g. the
  /// portal is waiting on its own confirm step — fall back to manual capture).
  Future<String?> payAllAndCapture(
      {Duration timeout = const Duration(seconds: 90)}) async {
    // A reference already on screen means it was paid — don't double-pay.
    final existing = await readReferenceIfPresent();
    if (existing != null) return existing;
    final ok =
        await _clickActionAndWait('Action.PAY_ALL_SAVED_INSTALLMENTS', timeout);
    if (!ok) return null;
    // The confirmation/reference page can take an extra reload to settle.
    for (var i = 0; i < 6; i++) {
      final ref = await readReferenceIfPresent();
      if (ref != null && ref.isNotEmpty) return ref;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  /// Pull a DOP list reference (mode prefix C / DC / NDC + ≥6 digits) out of a
  /// page. Longest-prefix wins so "NDC…" isn't clipped to "C…". Pure + testable.
  static String? parseReference(String html) {
    final m = RegExp(r'(?<![A-Z0-9])(NDC|DC|C)(\d{6,})').firstMatch(html);
    return m == null ? null : '${m.group(1)}${m.group(2)}';
  }

  // --- Deep Sync (per-account detail crawl) --------------------------------

  static const _detailLinkSel = "a[id*='ACCOUNT_NUMBER_ALL_ARRAY']";

  /// Walk every list page and open each account's detail page to read opening
  /// date, exact total deposit, pending/default installments. Calls [onAccount]
  /// as each detail parses (so progress persists even if interrupted). Returns
  /// the number of accounts read. Requires the WebView logged in.
  Future<int> deepSync({
    required Future<void> Function(AccountDetail) onAccount,
    void Function(int page, int totalPages, int done)? onProgress,
    Duration pageTimeout = const Duration(seconds: 60),
  }) async {
    if (!await navigateToAccountList()) {
      throw StateError('Could not open the account list.');
    }
    final total = totalPages(await currentPageHtml());
    var done = 0;

    for (var page = 1; page <= total; page++) {
      final n = await _detailLinkCount();
      for (var i = 0; i < n; i++) {
        final detail = await _openDetailAndBack(i, pageTimeout);
        if (detail != null && detail.accountNumber.isNotEmpty) {
          await onAccount(detail);
          done++;
        }
        onProgress?.call(page, total, done);
        if (await _isSessionExpired()) return done;
        if (await _isBlockedPage()) {
          throw StateError(
              'The portal blocked navigation after $done account(s). '
              'Please close Deep Sync, log in again, then retry.');
        }
      }
      if (page == total) break;
      if (await _clickNextAndWait(pageTimeout) != PageAdvance.moved) break;
    }
    return done;
  }

  Future<int> _detailLinkCount() async {
    final r = await controller.runJavaScriptReturningResult(
        "document.querySelectorAll(\"$_detailLinkSel\").length");
    return int.tryParse(_unwrap(r).replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  /// Click the i-th detail link, read the detail page, then go back to the list.
  Future<AccountDetail?> _openDetailAndBack(int i, Duration timeout) async {
    // Open detail
    _pageLoad = Completer<void>();
    final clicked = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var els = document.querySelectorAll("$_detailLinkSel");
        if (els[$i]) { els[$i].click(); return 'true'; }
        return 'false';
      })();
    '''));
    if (!clicked.contains('true')) {
      _pageLoad = null;
      return null;
    }
    await _awaitLoad(timeout);
    await _settle();
    AccountDetail? detail;
    try {
      detail = AgentDetailParser.parse(await currentPageHtml());
    } catch (_) {
      detail = null;
    }

    // Back to the list. IMPORTANT: never use window.history.back() here.
    // Finacle regenerates a one-shot transaction token on every server
    // navigation; a browser Back/Forward replays a spent token and the portal
    // kills the session with "Please close this window and try accessing the
    // application in a new browser window." (deep sync then dies after the
    // first account). We click the portal's own server-side Back control
    // instead, which mints a fresh token — exactly what a real user does.
    await _backToList(timeout);
    return detail;
  }

  /// Return to the account list from a detail page using the portal's own
  /// server-side Back control (see the warning in [_openDetailAndBack]).
  /// Returns true once the list table has re-rendered.
  Future<bool> _backToList(Duration timeout) async {
    _pageLoad = Completer<void>();
    final clicked =
        _unwrap(await controller.runJavaScriptReturningResult(_backJs));
    if (!clicked.contains('true')) {
      _pageLoad = null;
      return false;
    }
    await _awaitLoad(timeout);
    await _settle();
    return _waitForTable(const Duration(seconds: 20));
  }

  static const _backJs = r'''
    (function(){
      // Finacle "Back" is a server round-trip that regenerates a fresh token.
      // Prefer stable action/name attributes, then value/title/alt, then a
      // link/button whose visible text is exactly "Back".
      var sels = [
        'input[name*="Action.BACK"]','a[name*="Action.BACK"]',
        'input[name*="_BACK"]','a[name*="_BACK"]',
        'input[name*="BACK"]','a[name*="BACK"]',
        'input[value="Back"]','input[title="Back"]','input[alt="Back"]',
        'img[title="Back"]','img[alt="Back"]','button[title="Back"]'
      ];
      for (var s=0;s<sels.length;s++){
        var el=document.querySelector(sels[s]);
        if(el && !el.disabled){ (el.closest('a')||el).click(); return 'true'; }
      }
      var els=document.querySelectorAll(
        'a,input[type=button],input[type=submit],button,img');
      for(var i=0;i<els.length;i++){
        var t=(els[i].innerText||els[i].value||els[i].title||els[i].alt||'')
          .trim().toLowerCase();
        if(t==='back'||t==='back to list'||t==='go back'){
          (els[i].closest('a')||els[i]).click(); return 'true';
        }
      }
      return 'false';
    })();
  ''';

  /// Click "Next" and wait for the reloaded page's table. Retries a couple of
  /// times if the page stalls (legacy portal posts occasionally drop a load).
  /// Advance one page.
  ///
  /// This used to return a plain bool, and every caller read `false` as "that
  /// was the last page". It is not: it also meant "I clicked Next three times
  /// and the table never came back". Collapsing the two made a stalled sync
  /// indistinguishable from a finished one, so a run that died on page 3 of 47
  /// was reported to the agent as a success. Keep them apart.
  /// Click "Next" and confirm we actually arrived at [expectPage].
  ///
  /// The confirmation is the point. A rendered table alone proves nothing —
  /// the page we were already on has one — so a portal that silently drops the
  /// click reads as a successful move, and the walk finishes "complete" holding
  /// one page of a 47-page book.
  Future<PageAdvance> _clickNextAndWait(Duration timeout,
      {int? expectPage}) async {
    var backoff = const Duration(milliseconds: 500);
    for (var attempt = 0; attempt < 3; attempt++) {
      // Never post on top of the portal. If it is still digesting the last
      // click it has already told us so, and the page underneath the banner is
      // the one it kept — re-check before spending a retry on a click that
      // would only make things worse.
      final probe = await _listProbe();
      if (probe != null && PortalDom.isBusyBanner(probe.alert)) {
        await _yieldIfBusy(probe.alert);
        if (expectPage != null && (await _listProbe())?.page == expectPage) {
          return PageAdvance.moved;
        }
      }

      _pageLoad = Completer<void>();
      final clicked =
          _unwrap(await controller.runJavaScriptReturningResult(_nextJs));
      if (!clicked.contains('true')) {
        _pageLoad = null;
        return PageAdvance.lastPage; // no Next button — genuinely the end
      }
      await _awaitLoad(timeout);
      // No fixed settle here. It cost a flat 350 ms on every one of 48 pages —
      // 17 s of pure sleeping, about half the page walk — and bought nothing
      // that _waitForTable does not already prove: it polls until the portal's
      // OWN page label reads the number we asked for, which is a positive
      // confirmation rather than a hopeful pause.
      // Confirm the table rendered AND the portal moved to the page we asked
      // for, not merely that a table is on screen.
      if (await _waitForTable(_tableWait(timeout), expectPage: expectPage)) {
        return PageAdvance.moved;
      }
      // A stalled page is usually the portal being slow, not the click being
      // lost. Widen the gap before trying again rather than drumming on it.
      await Future<void>.delayed(backoff);
      backoff *= 3;
    }
    return PageAdvance.stalled; // clicked, never moved — a real failure
  }

  /// How long to wait for the table after a click, derived from the caller's
  /// page timeout rather than fixed at 20s.
  ///
  /// It is spent up to three times per page, so a hardcoded 20 meant a single
  /// stalled page cost a full minute before the agent was told anything — and
  /// made the failure path untestable at any sensible speed. A third of the
  /// page budget, floored so a slow portal still gets a fair chance.
  static Duration _tableWait(Duration pageTimeout) {
    final third = pageTimeout ~/ 3;
    if (third < const Duration(seconds: 2)) return const Duration(seconds: 2);
    if (third > const Duration(seconds: 20)) return const Duration(seconds: 20);
    return third;
  }

  Future<void> _awaitLoad(Duration timeout) async {
    final c = _pageLoad;
    if (c == null) return;
    try {
      await c.future.timeout(timeout);
    } catch (_) {
      // Handled timeout
    } finally {
      _pageLoad = null;
    }
  }

  /// Ask the portal to extend the session, if it is safe to do so right now.
  ///
  /// **This navigates.** The control is
  /// `<input type="Submit" name="Action.Action.Action.PREVENT_SESSION_TIMEOUT__">`
  /// — clicking it posts the whole form. Fired from a timer while a page walk
  /// was in flight it raced the walk's own post, and Finacle answered with
  /// "You clicked on a link or a button when your previous click was still
  /// being processed", then treated the out-of-sequence token as a replay and
  /// ended the session. That is the "sync reaches the account list, then says
  /// Session expired" report: the keep-alive was killing the thing it existed
  /// to protect.
  ///
  /// So it declines whenever anything else owns the page ([isDriving]), and it
  /// is unnecessary then anyway — every page the walk turns is itself a post,
  /// and a post is what resets the portal's five-minute idle timer. The
  /// keep-alive is only for a screen sitting idle with the agent looking at it.
  ///
  /// Returns true only if the click actually went out.
  Future<bool> keepSessionAlive() async {
    if (isDriving) {
      _t('keep-alive: DECLINED, the page is busy with a walk');
      return false;
    }
    return _drive(() async {
      try {
        final js = '(function(){var b=document.querySelector('
            '${jsonEncode(PortalDom.keepAliveButton)});'
            'if(b&&!b.disabled){b.click();return "true";}return "false";})();';
        final res = _unwrap(await controller.runJavaScriptReturningResult(js));
        if (!res.contains('true')) return false;
        _t('keep-alive: clicked (this navigates)');
        // It is a navigation: wait it out so the next thing to touch the page
        // does not post on top of it.
        _pageLoad = Completer<void>();
        await _awaitLoad(const Duration(seconds: 20));
        await _settle();
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  /// The portal's own idle allowance, in seconds, off the hidden
  /// `#sessionTimeout` field. 300 (five minutes) on every capture. 0 when the
  /// field is not there — i.e. we are not on an authenticated page.
  ///
  /// Worth reading rather than assuming: it is the budget the whole walk has to
  /// fit each of its steps inside.
  Future<int> sessionTimeoutSeconds() async {
    final js = '(function(){var e=document.querySelector('
        '${jsonEncode(PortalDom.sessionTimeoutField)});'
        'return e?String(e.value||""):"0";})();';
    try {
      return int.tryParse(
              _unwrap(await controller.runJavaScriptReturningResult(js))
                  .replaceAll(RegExp(r'[^0-9]'), '')) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  /// The full HTML of the page [_waitForTable] last accepted.
  ///
  /// The walk needs that exact document to parse, and it has just been fetched
  /// to validate it — fetching it a second time doubles the cost of the single
  /// most expensive operation in the loop.
  String? _validatedHtml;

  /// A few hundred bytes that answer the three questions the page walk asks
  /// after every click: which page is showing, is the table there, and is the
  /// portal complaining.
  ///
  /// Those used to be answered by serialising the whole document — 56 KB on a
  /// real listing page — up to three times per page, forty-eight times over.
  /// The DOM read was the walk, not the portal.
  ///
  /// Returns null when neither landmark is present, meaning we are not on a
  /// listing at all (or the portal was rebuilt) — callers fall back to reading
  /// the full document rather than trusting a probe that found nothing.
  Future<({int page, bool table, String alert})?> _listProbe() async {
    final js = '(function(){'
        'var l=document.querySelector(${jsonEncode(PortalDom.pageLabel)});'
        'var t=document.querySelector(${jsonEncode(PortalDom.listTable)});'
        'if(!l&&!t) return "";'
        'var a=document.querySelector(\'div[role="alert"]\');'
        'return JSON.stringify({p:l?(l.textContent||"").trim():"",'
        't:!!t,m:a?(a.textContent||"").slice(0,200):""});'
        '})();';
    try {
      final raw = _unwrap(await controller.runJavaScriptReturningResult(js));
      if (raw.isEmpty || raw == 'null' || raw == '""') return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        page: currentPage(m['p'] as String? ?? ''),
        table: m['t'] == true,
        alert: m['m'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Poll until the account table is present (handles late-rendering DOM).
  ///
  /// [expectPage], when given, additionally requires the portal's own
  /// "Page X of N" label to read X == expectPage. Without it this returns true
  /// for the page we were ALREADY on, which is how a dropped Next click used to
  /// pass for a successful move. See [currentPage].
  Future<bool> _waitForTable(Duration timeout, {int? expectPage}) async {
    final deadline = DateTime.now().add(timeout);
    _validatedHtml = null;
    while (DateTime.now().isBefore(deadline)) {
      final probe = await _listProbe();
      // Poll cheaply; pay for the full document only once, when the cheap
      // answer says the page we asked for has arrived.
      final looksRight = probe != null &&
          probe.table &&
          (expectPage == null || probe.page == expectPage);
      if (looksRight || probe == null) {
        final html = await currentPageHtml();
        if (_hasAccountTable(html) &&
            (expectPage == null || currentPage(html) == expectPage)) {
          _validatedHtml = html;
          return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return false;
  }

  Future<void> _settle() =>
      Future<void>.delayed(const Duration(milliseconds: 350));

  /// Click "Next". Exact Finacle action name first, loose fallbacks after.
  ///
  /// Never filter these on `[type="submit"]`: the portal writes `type="Submit"`
  /// and CSS attribute matching is case-sensitive for `type`, so the filter
  /// would match nothing. The `disabled` check is what keeps us off the
  /// greyed-out control at the end of the listing.
  static final _nextJs = '(function(){var els=document.querySelectorAll('
      '${jsonEncode(PortalDom.nextButton)});'
      'for(var i=0;i<els.length;i++){if(!els[i].disabled){els[i].click();'
      'return "true";}}return "false";})();';

  String _unwrap(Object result) {
    var s = result.toString();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {/* leave as-is */}
    }
    return s;
  }
}
