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

  /// Same, for the Accounts menu — the FIRST of the portal's two hops.
  void Function(FakePortal p)? onAccountsClick;

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
      onAccountsClick?.call(this);
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
/// The post-login dashboard, faithful to `recon/live/03_dashboard__after_login`.
///
/// The Accounts **submenu is not in this DOM**. That was worth getting right:
/// the fake used to carry the Enquire link here, which quietly encoded the
/// belief that the list was one click from login. The real capture settles it —
/// `03` has `HREF_Accounts` and no `Agent Enquire` anchor anywhere — and a walk
/// tuned against the old fake spent its clicks reaching for a link that could
/// not be there yet.
const dashboardHtml = '''
<html><body>
  <input type="Hidden" name="CustomAgentRDAccountFG.REPORTTITLE" value="RMDashboard">
  <a id="Accounts" name="HREF_Accounts" href="#">Accounts</a>
</body></html>''';

/// `AgentAccountHomePage` — the screen between Accounts and the list
/// (`recon/live/04_account_list__page_1`, despite its filename).
///
/// It has no table and no content at all, which is exactly why the old walk
/// could not tell reaching it apart from a click that went nowhere. The Enquire
/// link appears only here. Kept in a `<td>` on purpose: that is the shape that
/// used to make `_clickLinkByText` click the cell instead of the anchor.
const accountsHomeHtml = '''
<html><body>
  <input type="Hidden" name="CustomAgentRDAccountFG.REPORTTITLE" value="AgentAccountHomePage">
  <a id="Accounts" name="HREF_Accounts" href="#">Accounts</a>
  <table><tr><td><a href="/AgentRDActSummaryAllListing">Agent Enquire &amp; Update Screen</a></td></tr></table>
</body></html>''';

/// Finacle's double-post banner. Not fatal: the portal kept the first click and
/// the page underneath is the right one, so the engine must back off, not click.
const busyListHtml = '''
<html><body>
  <div role="alert">You clicked on a link or a button when your previous click
  was still being processed. System is considering your first request.</div>
  <table><tr><th>Account No</th><th>Account Name</th></tr>
  <tr><td>0123456789</td><td>A NAME</td></tr></table>
  <span class="paginationtxt1">Page 1 of 47</span>
</body></html>''';

/// Finacle's stale-transaction-token guard page.
const blockedHtml = '''
<html><body><p>Please close this window and try accessing the application
in a new browser window.</p></body></html>''';

/// The login page (`recon/live/01_login__before_submit`). Identified by the
/// password field's Finacle name, which no authenticated page carries.
const loginHtml = '''
<html><body>
  <input type="text" name="AuthenticationFG.USER_PRINCIPAL" id="AuthenticationFG.USER_PRINCIPAL">
  <input type="password" name="AuthenticationFG.ACCESS_CODE" id="AuthenticationFG.ACCESS_CODE">
  <input type="text" name="AuthenticationFG.VERIFICATION_CODE" id="AuthenticationFG.VERIFICATION_CODE">
  <img id="IMAGECAPTCHA">
</body></html>''';

/// The portal's "Your Session is Expired" interstitial
/// (`recon/live/06_session_expired__as_seen`). Only a fresh login clears it —
/// no amount of retrying the walk will.
const sessionExpiredHtml = '''
<html><head><title> Your Session is Expired </title></head><body>
  <b>Your Session is Expired</b>
  <a href="https://dopagent.indiapost.gov.in"><b>Click Here.</b></a>
</body></html>''';

/// The account list, page 1 of 47.
const listPage1Html = '''
<html><body>
  <table><tr><th>Account No</th><th>Account Name</th></tr>
  <tr><td>0123456789</td><td>A NAME</td></tr></table>
  <span>Page 1 of 47</span>
</body></html>''';
