import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:webview_flutter/webview_flutter.dart';

import '../../models/rd_account.dart';
import 'agent_detail_parser.dart';
import 'agent_list_parser.dart';
import 'aslaas_report_parser.dart';
import 'saved_installments_parser.dart';

/// What happened when the engine tried to turn a page.
///
/// Three states, not two: "I moved", "there was nothing to move to", and "I
/// tried and the page never came back". The last one is a failure and must not
/// be mistaken for the second.
enum PageAdvance { moved, lastPage, stalled }

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

  const SyncResult(this.accounts,
      {this.reachedList = true, this.error, this.complete = true});
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

  void notifyPageFinished() {
    final c = _pageLoad;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
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

  Future<bool> _isSessionExpired() async {
    final html = await currentPageHtml();
    return html.contains('Session is Expired') ||
        html.contains('Session Expired');
  }

  /// Detects Finacle's stale-transaction-token guard page — "Please close this
  /// window and try accessing the application in a new browser window." — shown
  /// when the portal thinks a spent/out-of-sequence token was replayed (e.g. by
  /// a browser Back/Forward). Deep Sync avoids triggering it, but we still probe
  /// for it so a poisoned session surfaces as a clear error instead of silently
  /// ending after one account.
  Future<bool> _isBlockedPage() async {
    final html = (await currentPageHtml()).toLowerCase();
    return html.contains('close this window') &&
        html.contains('new browser window');
  }

  /// Is the account list currently rendered? (has the table + "Page X of N").
  Future<bool> _onListPage() async {
    final html = await currentPageHtml();
    return _hasAccountTable(html);
  }

  /// Public probe so the screen can auto-start once login lands on the list.
  Future<bool> isOnListPage() => _onListPage();

  /// True once we're inside the authenticated agent portal (Dashboard or list) —
  /// i.e. login succeeded. Detected by the authenticated menu / pagination
  /// controls, which the login page doesn't have.
  Future<bool> isAuthenticated() async {
    const js =
        "(function(){return (document.querySelector('#Accounts, a[name=\"HREF_Accounts\"], input[name*=\"GOTO_NEXT\"]')) ? 'true' : 'false';})();";
    return _unwrap(await controller.runJavaScriptReturningResult(js))
        .contains('true');
  }

  static bool _hasAccountTable(String html) {
    final lower = html.toLowerCase();
    return (lower.contains('account no') || lower.contains('account name')) &&
        RegExp(r'Page\s+\d+\s+of\s+\d+', caseSensitive: false).hasMatch(html);
  }

  static int totalPages(String html) {
    final m =
        RegExp(r'Page\s+\d+\s+of\s+(\d+)', caseSensitive: false).firstMatch(html);
    return m != null ? int.parse(m.group(1)!) : 1;
  }

  // --- Auto-navigation -----------------------------------------------------

  /// Reach the account list from wherever login lands.
  ///
  /// Confirmed from real captures, login lands on the **Dashboard**. The path to
  /// the list is: click "Accounts" (a menu link with id="Accounts") -> then the
  /// "Agent Enquire & Update Screen" link that appears -> the list (Page 1/47).
  /// This walks that path, preferring the Enquire link when it's already
  /// present, and falls back to opening the Accounts menu first.
  Future<bool> navigateToAccountList({
    Duration stepTimeout = const Duration(seconds: 45),
  }) async {
    for (var hop = 0; hop < 4; hop++) {
      if (await _onListPage()) return true;

      // Arm the page-load wait BEFORE clicking so a fast navigation can't
      // complete before we start listening.
      _pageLoad = Completer<void>();

      var clicked = await _clickEnquireLink();
      // …otherwise open the Accounts menu (stable id) to reveal it.
      clicked = clicked ||
          await _clickSelector(
              '#Accounts, a[name="HREF_Accounts"], #Accounts a');

      if (!clicked) {
        _pageLoad = null;
        break;
      }

      // The "Agent Enquire & Update Screen" step is the slow one: the portal can
      // silently drop the click, or the session can lapse, while we wait. So
      // rather than blocking for the whole timeout, wait in ~11s slices and
      // AUTO-CLICK the link again each slice it's still loading.
      const slice = Duration(seconds: 11);
      final tries = (stepTimeout.inSeconds ~/ slice.inSeconds).clamp(1, 5);
      for (var t = 0; t < tries; t++) {
        await _awaitLoad(slice);
        await _settle();
        if (await _onListPage()) return true;
        if (await _isSessionExpired()) return false;
        // Still not there — nudge the Enquire link again and wait another slice.
        _pageLoad = Completer<void>();
        if (!await _clickEnquireLink()) {
          _pageLoad = null;
          break;
        }
      }
    }
    return _onListPage();
  }

  /// Click the "Agent Enquire & Update Screen" link — by its stable name/id
  /// first (exact from the portal DOM), then by visible text. Returns true if
  /// something was clicked.
  Future<bool> _clickEnquireLink() async {
    var c = await _clickSelector('a[name*="Enquire"], a[id*="Enquire"]');
    c = c ||
        await _clickLinkByText(const [
          'agent enquire & update',
          'enquire & update',
          'enquire and update',
          'update screen',
        ]);
    return c;
  }

  /// Click the first element matching a CSS selector. Returns true if one was
  /// clicked.
  Future<bool> _clickSelector(String selector) async {
    final js = '''
      (function() {
        var el = document.querySelector(${jsonEncode(selector)});
        if (el) { (el.closest('a') || el).click(); return 'true'; }
        return 'false';
      })();
    ''';
    return _unwrap(await controller.runJavaScriptReturningResult(js))
        .contains('true');
  }

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
            if (t && t.indexOf(needles[n]) !== -1) {
              var clickable = els[i].closest('a') || els[i];
              clickable.click();
              return 'true';
            }
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
  }) async {
    if (await _isSessionExpired()) {
      return const SyncResult([],
          reachedList: false,
          error: 'Session expired — please log in again.',
          complete: false);
    }
    if (!await _onListPage()) {
      final ok = await navigateToAccountList();
      if (!ok) {
        return const SyncResult([],
            reachedList: false,
            error:
                'Could not open the account list. Open Accounts → Agent Inquire '
                'and Update, then tap Sync.',
            complete: false);
      }
    }

    // START AT PAGE 1. This used to read whichever page the WebView happened to
    // be showing and call it page 1 — and a sync LEAVES the list on the last
    // page (see fillDetails). So a second Sync in the same session read page 47,
    // stamped those ten accounts as #1-#10, and every short code from there on
    // was wrong and collided with the real #1-#10.
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
    final firstHtml = await currentPageHtml();
    final total = totalPages(firstHtml);
    var walked = 0; // pages actually read — compared against `total` at the end

    for (var page = 1; page <= total; page++) {
      final html = page == 1 ? firstHtml : await currentPageHtml();
      for (final r in AgentListParser.parsePage(html)) {
        byAccount.putIfAbsent(r.accountNumber, () => r);
      }
      onProgress?.call(page, total, byAccount.length);
      if (page == total) {
        walked = page;
        break;
      }

      final advance = await _clickNextAndWait(pageTimeout);
      if (advance != PageAdvance.moved) {
        // Finacle's stale-token guard stops the table rendering, which looks
        // exactly like a stall. Probe for it so the agent is told what actually
        // happened instead of being handed a short book.
        final blocked = await _isBlockedPage();
        return SyncResult(_serialised(byAccount, complete: false),
            reachedList: true,
            error: blocked
                ? 'The portal blocked navigation at page $page of $total. '
                    'Log in again, then run Sync.'
                : 'Sync stopped at page $page of $total — only '
                    '${byAccount.length} accounts were read. Run Sync again; '
                    'nothing already on the phone was changed.',
            complete: false);
      }
      walked = page + 1;
      if (await _isSessionExpired()) {
        return SyncResult(_serialised(byAccount, complete: false),
            reachedList: true,
            error: 'Session expired at page $page of $total — synced what '
                'loaded. Run Sync again.',
            complete: false);
      }
    }

    // Belt and braces: the loop can only end early via the paths above, but a
    // future edit must not be able to reintroduce a silent short read.
    if (walked < total) {
      return SyncResult(_serialised(byAccount, complete: false),
          reachedList: true,
          error: 'Sync ended at page $walked of $total — run it again.',
          complete: false);
    }
    return SyncResult(_serialised(byAccount));
  }

  /// Stamp each account with its 1-based position in the portal listing.
  ///
  /// [complete] must be false when the walk stopped early. A short read only
  /// ever holds a PREFIX of the book, so numbering it 1..N is right for those
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
    for (var i = 0; i < list.length; i++) {
      list[i] = list[i].copyWith(serial: i + 1);
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
  Future<bool> _gotoPage(int page, Duration timeout) async {
    _pageLoad = Completer<void>();
    final ok = _unwrap(await controller.runJavaScriptReturningResult('''
      (function(){
        var inp=document.querySelector('input[name*="REQUESTED_PAGE_NUMBER" i][type="text"]')
          || document.querySelector('input[name*="PAGE_NO" i][type="text"]')
          || document.querySelector('input[name*="GOTO_PAGE" i][type="text"]')
          || document.querySelector('input[name*="PAGE" i][type="text"]');
        var btn=document.querySelector('input[name*="GOTO_PAGE" i][type="submit"]')
          || document.querySelector('input[name*="GOTO_PAGE" i][type="button"]')
          || document.querySelector('input[name*="GOTO_PAGE" i]')
          || document.querySelector('input[value="Go" i]');
        if(!inp||!btn) return 'false';
        inp.value='$page';
        inp.dispatchEvent(new Event('change',{bubbles:true}));
        btn.click(); return 'true';
      })();
    '''));
    if (!ok.contains('true')) {
      _pageLoad = null;
      return false;
    }
    await _awaitLoad(timeout);
    await _settle();
    return _waitForTable(const Duration(seconds: 20));
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
  Future<bool> _clickAccountAnchor(String accountNumber, Duration timeout) async {
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

    // 3. Walk the report pages.
    final out = <String, String>{};
    var html = await currentPageHtml();
    if (!RegExp('aslaas number', caseSensitive: false).hasMatch(html)) {
      onDiag?.call('ASLAAS report did not open (${html.length} chars)');
      return const {};
    }
    final total = totalPages(html);
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
  Future<AccountDetail?> fetchAccountDetail({
    required String accountNumber,
    int? serialHint,
    void Function(String message)? onProgress,
    Duration pageTimeout = const Duration(seconds: 60),
  }) async {
    if (!await _onListPage() && !await navigateToAccountList()) return null;
    final total = totalPages(await currentPageHtml());

    if (serialHint != null && serialHint > 0) {
      final page = ((serialHint - 1) ~/ 10) + 1;
      if (page >= 1 && page <= total) {
        onProgress?.call('Opening page $page…');
        await _gotoPage(page, pageTimeout);
      }
      if (await _clickAccountAnchor(accountNumber, pageTimeout)) {
        onProgress?.call('Reading account details…');
        return _parseDetailAndBack(pageTimeout);
      }
      await _gotoPage(1, pageTimeout); // fast path missed — restart the scan
    }

    for (var page = 1; page <= total; page++) {
      onProgress?.call('Searching page $page of $total…');
      if (await _clickAccountAnchor(accountNumber, pageTimeout)) {
        onProgress?.call('Reading account details…');
        return _parseDetailAndBack(pageTimeout);
      }
      if (page == total) break;
      if (await _clickNextAndWait(pageTimeout) != PageAdvance.moved) break;
    }
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
  /// FAST PATH: when [serialByAccount] is given (each account's 1-based position
  /// from the last sync, 10 rows/page), we jump straight to the page holding
  /// each account instead of scanning all ~47 pages. A full sequential scan
  /// still runs for anything the fast path didn't find (unknown serial, or the
  /// portal list changed since sync), so an account is never silently skipped.
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
      final byPage = <int, Set<String>>{};
      for (final a in accountNumbers) {
        final s = serialByAccount[a] ?? 0;
        if (s <= 0) continue;
        final page = (((s - 1) ~/ 10) + 1).clamp(1, total);
        byPage.putIfAbsent(page, () => <String>{}).add(a);
      }
      for (final page in byPage.keys.toList()..sort()) {
        if (!await _gotoPage(page, pageTimeout)) break;
        await selectPayMode(mode);
        found.addAll(await _selectMatchingOnPage(byPage[page]!));
        onProgress?.call(page, total, found.length);
        if (await _isSessionExpired()) {
          return ListPrepResult(found, accountNumbers.length,
              error: 'Session expired — selected ${found.length}.');
        }
      }
    }

    // --- Correctness net: sequential scan for anything still missing --------
    final remaining = accountNumbers.difference(found);
    if (remaining.isNotEmpty) {
      await _gotoPage(1, pageTimeout); // reset to the top (no-op if already there)
      for (var page = 1; page <= total; page++) {
        await selectPayMode(mode);
        found.addAll(await _selectMatchingOnPage(remaining));
        onProgress?.call(page, total, found.length);
        if (found.length >= accountNumbers.length) break;
        if (page == total) break;
        if (await _clickNextAndWait(pageTimeout) != PageAdvance.moved) break;
        if (await _isSessionExpired()) {
          return ListPrepResult(found, accountNumbers.length,
              error: 'Session expired at page $page — selected ${found.length}.');
        }
      }
    }

    await selectPayMode(mode);
    final saved = await saveSelection(pageTimeout);
    return ListPrepResult(found, accountNumbers.length,
        saved: saved, error: saved ? null : 'Could not click Save on the portal.');
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
      return (jsonDecode(raw) as Map).map(
          (k, v) => MapEntry(k as String, (v as String).trim()));
    } catch (_) {
      return const {};
    }
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

  /// Prepare the installment screen for payment. "Pay All Saved Installments"
  /// already pays every selected account as ONE installment by default, so a
  /// plain single-installment cash row needs NO keying at all. This only keys
  /// the rows that genuinely differ from that default:
  ///   * advance deposits (>1 installment) — so the rebate is calculated, and
  ///   * cheque rows — the cheque number/bank must be entered.
  /// Each such row is keyed with Get-Rebate-&-Default + Save so it becomes
  /// Modified=YES. NEVER pays. Robust to row reordering: it repeatedly finds the
  /// next un-keyed target row, reads THAT row's account off the page, and keys
  /// that account's own installment — so a count can't land on the wrong
  /// customer. Returns how many of the rows-that-needed-keying got saved
  /// ([InstallmentFillResult.total] is that count, not the whole list).
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
    // Only these rows need explicit keying; every other row rides the portal's
    // default of one installment when Pay All runs.
    bool needsKey(String acc) {
      final n = installmentsByAccount[acc] ?? 1;
      final chqNo = chequeByAccount?[acc]?.chequeNo ?? '';
      return n > 1 || chqNo.isNotEmpty;
    }

    final targets = installmentsByAccount.keys.where(needsKey).toSet();
    final rebates = <String, ({int? rebate, int? defaultFee})>{};
    if (targets.isEmpty) {
      // Nothing to key: an all-single cash list. Pay All handles it as-is.
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
      // did not give us.
      reb ??= await _rowNumArray('RD_REBATE_ARRAY', idx);
      def ??= await _rowNumArray('RD_DEFAUT_FEE_ARRAY', idx);

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
    final raw = _unwrap(await controller.runJavaScriptReturningResult(js)).trim();
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
    final m =
        RegExp(r'(?<![A-Z0-9])(NDC|DC|C)(\d{6,})').firstMatch(html);
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
  Future<PageAdvance> _clickNextAndWait(Duration timeout) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      _pageLoad = Completer<void>();
      final clicked =
          _unwrap(await controller.runJavaScriptReturningResult(_nextJs));
      if (!clicked.contains('true')) {
        _pageLoad = null;
        return PageAdvance.lastPage; // no Next button — genuinely the end
      }
      await _awaitLoad(timeout);
      await _settle();
      // Confirm the table actually rendered before declaring success.
      if (await _waitForTable(const Duration(seconds: 20))) {
        return PageAdvance.moved;
      }
    }
    return PageAdvance.stalled; // clicked, never rendered — a real failure
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

  /// Prevent session timeout by clicking the portal's keep-alive button if present.
  Future<bool> keepSessionAlive() async {
    const js = '''
      (function() {
        var btn = document.querySelector('input[name*="PREVENT_SESSION_TIMEOUT" i]')
          || document.querySelector('input[value*="Prevent Session Timeout" i]');
        if (btn && !btn.disabled) {
          btn.click();
          return 'true';
        }
        return 'false';
      })();
    ''';
    try {
      final res = _unwrap(await controller.runJavaScriptReturningResult(js));
      return res.contains('true');
    } catch (_) {
      return false;
    }
  }

  /// Poll until the account table is present (handles late-rendering DOM).
  Future<bool> _waitForTable(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_hasAccountTable(await currentPageHtml())) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  Future<void> _settle() =>
      Future<void>.delayed(const Duration(milliseconds: 350));

  static const _nextJs = r'''
    (function() {
      var el = document.querySelector(
        'input[name*="GOTO_NEXT"], input[title="Next"], input[alt="Next"]');
      if (el && !el.disabled) { el.click(); return 'true'; }
      return 'false';
    })();
  ''';

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
