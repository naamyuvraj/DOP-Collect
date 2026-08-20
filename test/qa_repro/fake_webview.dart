import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A scriptable stand-in for the DOP portal behind a real [WebViewController].
///
/// QA harness only. It lets the *real* [PortalSyncEngine] run its actual control
/// flow — arm completer, click, wait, re-click — against a page whose behaviour
/// we control, and records every script the engine injects so a test can assert
/// on what the engine DID, not on what it returned.
class FakePortal {
  FakePortal(this.html);

  /// Current document. Assign to simulate a navigation.
  String html;

  /// Every script the engine injected, in order.
  final List<String> injected = <String>[];

  /// Clicks the engine aimed at the "Agent Enquire & Update" link.
  int enquireClicks = 0;

  /// Clicks the engine aimed at the Accounts menu.
  int accountsMenuClicks = 0;

  /// When false, click scripts report `'false'` (nothing found to click).
  bool clickableEnquire = true;
  bool clickableAccountsMenu = true;

  /// Called after each click so a scenario can navigate, poison, or do nothing.
  void Function(FakePortal p)? onEnquireClick;

  int get totalClicks => enquireClicks + accountsMenuClicks;

  String _respond(String js) {
    injected.add(js);
    if (js.contains('outerHTML')) return jsonEncode(html);
    // Faithful to the real thing: a click only "lands" if the element the
    // selector is looking for is actually present in the current document.
    if (js.contains('#Accounts')) {
      if (!clickableAccountsMenu || !html.contains('Accounts')) {
        return jsonEncode('false');
      }
      accountsMenuClicks++;
      return jsonEncode('true');
    }
    if (js.contains('Enquire') || js.contains('enquire')) {
      if (!clickableEnquire || !html.contains('Enquire')) {
        return jsonEncode('false');
      }
      enquireClicks++;
      onEnquireClick?.call(this);
      return jsonEncode('true');
    }
    return jsonEncode('false');
  }
}

class FakeWebViewPlatform extends WebViewPlatform {
  FakeWebViewPlatform(this.portal);
  final FakePortal portal;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      _FakeController(params, portal);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params, this.portal) : super.implementation();
  final FakePortal portal;

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      portal._respond(javaScript);

  @override
  Future<void> runJavaScript(String javaScript) async {
    portal.injected.add(javaScript);
  }

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

/// A dashboard: authenticated menu present, no account table.
const dashboardHtml = '''
<html><body>
  <a id="Accounts" name="HREF_Accounts" href="#">Accounts</a>
  <table><tr><td><a href="/AgentRDActSummaryAllListing">Agent Enquire &amp; Update Screen</a></td></tr></table>
</body></html>''';

/// Finacle's stale-transaction-token guard page.
const blockedHtml = '''
<html><body><p>Please close this window and try accessing the application
in a new browser window.</p></body></html>''';

/// The account list, page 1 of 47.
const listPage1Html = '''
<html><body>
  <table><tr><th>Account No</th><th>Account Name</th></tr>
  <tr><td>0123456789</td><td>A NAME</td></tr></table>
  <span>Page 1 of 47</span>
</body></html>''';
