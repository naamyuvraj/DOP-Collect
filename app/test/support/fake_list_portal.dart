import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A scriptable stand-in for the DOP account listing, behind a real
/// [WebViewController], so the REAL [PortalSyncEngine.syncAllPages] runs its
/// actual control flow against a portal whose misbehaviour we choose.
///
/// The listing is the only part of the portal modelled: N pages of accounts and
/// a Next button. What makes it useful is [dropNextOnPage] — the portal
/// swallowing a click while leaving the current page rendered, which is the
/// failure the walk has to be able to tell apart from a successful move.
class FakeListPortal {
  FakeListPortal({required this.pages, this.perPage = 10});

  /// How many pages the listing advertises in "Page X of N".
  final int pages;
  final int perPage;

  int current = 1;

  /// Pages on which a Next click reports success but does NOT navigate.
  final Set<int> dropNextOnPage = <int>{};

  /// Pages that render the chrome but no account rows.
  final Set<int> blankPages = <int>{};

  /// Rows on [page] whose due-date cell is unreadable.
  final Map<int, int> unreadableRowsOnPage = <int, int>{};

  /// Rows on [page] whose due-date cell is BLANK — accounts that reached term.
  /// They occupy a row in the listing but never become an [RdAccount], which is
  /// exactly what the short code has to keep counting.
  final Map<int, int> maturedRowsOnPage = <int, int>{};

  int nextClicks = 0;

  /// Pages a GOTO_PAGE jump actually landed on, in order.
  final List<int> jumps = <int>[];

  /// Pages whose account numbers were read off, in order.
  final List<int> pageReads = <int>[];

  /// Rewrites the account number at row [i] of a page — used to put the listing
  /// out of account-number order, which is what an agent gets after clicking a
  /// column header to sort by name.
  final Map<int, Map<int, String>> renumber = <int, Map<int, String>>{};

  /// Account numbers ticked, in the order the portal was asked to tick them.
  final List<String> selected = <String>[];

  bool saved = false;

  /// Non-null while the portal is showing an account's detail page.
  String? openDetail;

  /// Accounts whose detail page renders no readable fields.
  final Set<String> blankDetail = <String>{};

  /// Detail pages opened, in order.
  final List<String> detailOpens = <String>[];

  /// Whether Finacle's Back control is on the detail page.
  bool backWorks = true;

  /// Serve Finacle's stale-transaction-token guard instead of the listing —
  /// what a browser Back onto a spent page earns.
  bool blocked = false;

  /// Render the account cells as <span>s with no href, the way the whole-book
  /// print preview does. Clicking one does nothing.
  bool previewMarkup = false;

  /// Called after a click that navigates, so the test can release the engine's
  /// page-load completer.
  void Function()? onNavigated;

  /// The account numbers this portal renders on [page], in row order —
  /// including the matured rows, which are rows on the portal like any other.
  List<String> accountsOn(int page) => [
        for (var i = 0; i < perPage; i++)
          renumber[page]?[i] ??
              '02000${((page - 1) * perPage + i).toString().padLeft(7, '0')}',
      ];

  /// One account's "ViewRDAccountDetails" page, label-driven like the real one.
  String get _detailHtml {
    final acct = openDetail!;
    if (blankDetail.contains(acct)) {
      return '<html><body><span>Account Details</span>'
          '${backWorks ? '<input type="submit" name="Action.BACK" value="Back">' : ''}'
          '</body></html>';
    }
    return '<html><body>'
        '<table>'
        '<tr><td>Account No</td><td>$acct</td></tr>'
        '<tr><td>Account Opening Date</td><td>01-04-2021</td></tr>'
        '<tr><td>Total Deposit Amount</td><td>60,000.00</td></tr>'
        '<tr><td>Date of Last Deposit</td><td>15-08-2026</td></tr>'
        '<tr><td>Pending installments</td><td>2</td></tr>'
        '<tr><td>Default installments</td><td>1</td></tr>'
        '</table>'
        '${backWorks ? '<input type="submit" name="Action.BACK" value="Back">' : ''}'
        '</body></html>';
  }

  String get html {
    if (blocked) {
      return '<html><body>Please close this window and try accessing the '
          'application in a new browser window.</body></html>';
    }
    if (openDetail != null) return _detailHtml;
    final rows = StringBuffer();
    if (!blankPages.contains(current)) {
      final bad = unreadableRowsOnPage[current] ?? 0;
      final matured = maturedRowsOnPage[current] ?? 0;
      final numbers = accountsOn(current);
      for (var i = 0; i < perPage; i++) {
        final n = numbers[i];
        final due = i < bad
            ? 'N/A'
            : i < bad + matured
                ? ''
                : '15-09-2026';
        rows.write('<tr><td><input type="checkbox"></td><td>$n</td>'
            '<td>NAME $n</td><td>1,000.00 Cr.</td><td>12</td><td>$due</td></tr>');
      }
    }
    return '<html><body><table>'
        '<tr><th>Select</th><th>Account No</th><th>Account Name</th>'
        '<th>Denomination</th><th>Month Paid Upto</th>'
        '<th>Next RD Installment Due Date</th></tr>$rows</table>'
        '<input type="text" name="REQUESTED_PAGE_NUMBER">'
        '<input type="submit" name="GOTO_PAGE" value="Go">'
        '<input type="submit" name="GOTO_NEXT" value="Next">'
        '<span>Page $current of $pages</span>'
        '</body></html>';
  }

  String respond(String js) {
    if (js.contains('outerHTML')) return jsonEncode(html);
    // Clicking an account number opens its detail page. On the real listing
    // these are <a href> anchors; the click navigates only if the account is
    // actually on the page in front of us.
    if (js.contains('as[i].click()')) {
      final want = RegExp(r'var t="(\d+)"').firstMatch(js)?.group(1);
      if (want == null || !accountsOn(current).contains(want)) {
        return jsonEncode('false');
      }
      if (previewMarkup) {
        // The element is there and click() is called, but a <span> has nowhere
        // to go. The portal reports success and stays exactly where it was.
        return jsonEncode('true');
      }
      openDetail = want;
      detailOpens.add(want);
      onNavigated?.call();
      return jsonEncode('true');
    }
    // Finacle's Back — a server round trip, not history.back().
    if (js.contains('Action.BACK')) {
      if (openDetail == null || !backWorks) return jsonEncode('false');
      openDetail = null;
      onNavigated?.call();
      return jsonEncode('true');
    }
    // Ticking the boxes. The engine does this by walking Finacle's per-row ids;
    // the portal side of that is simply "which of these are on this page".
    if (js.contains('SELECT_INDEX_ARRAY')) {
      final raw = RegExp(r'var targets = (\[.*?\]);').firstMatch(js);
      final targets = raw == null
          ? const <String>[]
          : (jsonDecode(raw.group(1)!) as List).cast<String>();
      final here = accountsOn(current).toSet();
      final hit = targets.where(here.contains).toList();
      selected.addAll(hit);
      return jsonEncode(jsonEncode(hit));
    }
    // Which accounts this page is showing — what the binary-search probe reads
    // to decide which half of the book to look in next.
    if (js.contains('ACCOUNT_NUMBER_ALL_ARRAY') &&
        js.contains('JSON.stringify')) {
      pageReads.add(current);
      return jsonEncode(jsonEncode(
          blankPages.contains(current) ? <String>[] : accountsOn(current)));
    }
    // How many rows this page holds — asked before any serial->page arithmetic.
    if (js.contains('ACCOUNT_NUMBER_ALL_ARRAY') && js.contains('length')) {
      return jsonEncode(
          blankPages.contains(current) ? '0' : perPage.toString());
    }
    if (js.contains('PAY_MODE_SELECTED_FOR_TRN')) return jsonEncode('true');
    if (js.contains('SAVE_ACCOUNTS')) {
      saved = true;
      onNavigated?.call();
      return jsonEncode('true');
    }
    if (js.contains('GOTO_NEXT')) {
      nextClicks++;
      if (dropNextOnPage.contains(current)) {
        // The portal accepted the click and did nothing. The page it was
        // already showing is still there, table and all.
        onNavigated?.call();
        return jsonEncode('true');
      }
      if (current < pages) current++;
      onNavigated?.call();
      return jsonEncode('true');
    }
    if (js.contains('GOTO_PAGE') || js.contains('REQUESTED_PAGE_NUMBER')) {
      // The engine writes the page number with jsonEncode, i.e. double quotes.
      // Matching only single quotes silently sent every jump to page 1 — which
      // is the very bug these tests exist to catch.
      final m = RegExp(r'''inp\.value=['"](\d+)['"]''').firstMatch(js);
      current = int.tryParse(m?.group(1) ?? '1') ?? 1;
      jumps.add(current);
      onNavigated?.call();
      return jsonEncode('true');
    }
    return jsonEncode('false');
  }
}

class FakeListPlatform extends WebViewPlatform {
  FakeListPlatform(this.portal);
  final FakeListPortal portal;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      _Controller(params, portal);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params, this.portal) : super.implementation();
  final FakeListPortal portal;

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      portal.respond(javaScript);

  @override
  Future<void> runJavaScript(String javaScript) async {}
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
      PlatformNavigationDelegate handler) async {}
}
