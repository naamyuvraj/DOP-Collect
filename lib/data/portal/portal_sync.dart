import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:webview_flutter/webview_flutter.dart';

import '../../models/rd_account.dart';
import 'agent_detail_parser.dart';
import 'agent_list_parser.dart';
import 'saved_installments_parser.dart';

/// Result of an auto-sync attempt.
class SyncResult {
  final List<RdAccount> accounts;
  final bool reachedList;
  final String? error;

  const SyncResult(this.accounts, {this.reachedList = true, this.error});
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
    _pageLoad = null;
    if (c != null && !c.isCompleted) c.complete();
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

      // Prefer the Enquire link by its stable name attribute (exact from the
      // portal DOM), then by visible text…
      var clicked =
          await _clickSelector('a[name*="Enquire"], a[id*="Enquire"]');
      clicked = clicked ||
          await _clickLinkByText(const [
            'agent enquire & update',
            'enquire & update',
            'enquire and update',
            'update screen',
          ]);
      // …otherwise open the Accounts menu (stable id) to reveal it.
      clicked = clicked ||
          await _clickSelector(
              '#Accounts, a[name="HREF_Accounts"], #Accounts a');

      if (!clicked) {
        _pageLoad = null;
        break;
      }
      await _pageLoad!.future
          .timeout(stepTimeout, onTimeout: () => _pageLoad = null);
      await _settle();
      if (await _isSessionExpired()) return false;
    }
    return _onListPage();
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
          reachedList: false, error: 'Session expired — please log in again.');
    }
    if (!await _onListPage()) {
      final ok = await navigateToAccountList();
      if (!ok) {
        return const SyncResult([],
            reachedList: false,
            error:
                'Could not open the account list. Open Accounts → Agent Inquire '
                'and Update, then tap Sync.');
      }
    }

    final byAccount = <String, RdAccount>{};
    final firstHtml = await currentPageHtml();
    final total = totalPages(firstHtml);

    for (var page = 1; page <= total; page++) {
      final html = page == 1 ? firstHtml : await currentPageHtml();
      for (final r in AgentListParser.parsePage(html)) {
        byAccount.putIfAbsent(r.accountNumber, () => r);
      }
      onProgress?.call(page, total, byAccount.length);
      if (page == total) break;

      final moved = await _clickNextAndWait(pageTimeout);
      if (!moved) break;
      if (await _isSessionExpired()) {
        return SyncResult(_serialised(byAccount),
            reachedList: true,
            error: 'Session expired at page $page — synced what loaded.');
      }
    }
    return SyncResult(_serialised(byAccount));
  }

  List<RdAccount> _serialised(Map<String, RdAccount> byAccount) {
    final list = byAccount.values.toList();
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
        var inp=document.querySelector('input[name*="PAGE_NO" i][type="text"]')
          || document.querySelector('input[name*="GOTO_PAGE" i][type="text"]')
          || document.querySelector('input[name*="PAGE" i][type="text"]');
        var btn=document.querySelector('input[name*="GOTO_PAGE" i]');
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
      if (!await _clickNextAndWait(pageTimeout)) break;
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
      if (!await _clickNextAndWait(pageTimeout)) break;
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

  /// Walk every list page, tick the lot's accounts (mode set on each page so it
  /// survives the reloads), then Save. Stops early once all are found.
  Future<ListPrepResult> prepareList({
    required Set<String> accountNumbers,
    required String mode,
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
    for (var page = 1; page <= total; page++) {
      await selectPayMode(mode);
      found.addAll(await _selectMatchingOnPage(accountNumbers));
      onProgress?.call(page, total, found.length);
      if (found.length >= accountNumbers.length) break;
      if (page == total) break;
      if (!await _clickNextAndWait(pageTimeout)) break;
      if (await _isSessionExpired()) {
        return ListPrepResult(found, accountNumbers.length,
            error: 'Session expired at page $page — selected ${found.length}.');
      }
    }

    await selectPayMode(mode);
    final saved = await saveSelection(pageTimeout);
    return ListPrepResult(found, accountNumbers.length,
        saved: saved, error: saved ? null : 'Could not click Save on the portal.');
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
      if (!await _clickNextAndWait(pageTimeout)) break;
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
  Future<bool> _clickNextAndWait(Duration timeout) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      _pageLoad = Completer<void>();
      final clicked =
          _unwrap(await controller.runJavaScriptReturningResult(_nextJs));
      if (!clicked.contains('true')) {
        _pageLoad = null;
        return false; // no Next button -> last page
      }
      await _awaitLoad(timeout);
      await _settle();
      // Confirm the table actually rendered before declaring success.
      if (await _waitForTable(const Duration(seconds: 20))) return true;
    }
    return false;
  }

  Future<void> _awaitLoad(Duration timeout) async {
    final c = _pageLoad ??= Completer<void>();
    await c.future.timeout(timeout, onTimeout: () => _pageLoad = null);
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
