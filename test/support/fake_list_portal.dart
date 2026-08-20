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

  int nextClicks = 0;

  /// Called after a click that navigates, so the test can release the engine's
  /// page-load completer.
  void Function()? onNavigated;

  String get html {
    final rows = StringBuffer();
    if (!blankPages.contains(current)) {
      final bad = unreadableRowsOnPage[current] ?? 0;
      for (var i = 0; i < perPage; i++) {
        final n =
            '02000${((current - 1) * perPage + i).toString().padLeft(7, '0')}';
        final due = i < bad ? 'N/A' : '15-09-2026';
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
      final m = RegExp(r"inp\.value='(\d+)'").firstMatch(js);
      current = int.tryParse(m?.group(1) ?? '1') ?? 1;
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
