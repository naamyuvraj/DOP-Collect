import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dop_collect/data/portal/portal_dom.dart';
import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Drives the sync engine through a **real Android WebView** against
/// `tool/mock_portal.py` — the captured DOP portal, replayed navigably.
///
/// Why this and not a unit test: every sync defect in this codebase's history
/// has been navigation timing, not parsing. A dropped click, a page-finish that
/// fired before the DOM changed, a screen misread as a failure. None of it
/// reproduces against a string of HTML, because none of it is about the HTML —
/// it is about a real browser issuing real navigations and telling us about
/// them late. This is the cheapest harness that has those properties, and it
/// costs no live banking session.
///
/// Run it:
/// ```
/// python3 tool/mock_portal.py &            # on the host
/// flutter test integration_test/portal_sync_mock_test.dart -d emulator-5554
/// ```
/// 10.0.2.2 is the emulator's alias for the host loopback. Cleartext to it is
/// permitted by `android/app/src/debug/res/xml/network_security_config.xml`,
/// which is a **debug-only** overlay — the release policy still forbids it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const base = 'http://10.0.2.2:8799';

  Future<Map<String, dynamic>> control(String path) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$base$path'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// Server-side click counters, so a test can assert on what the portal
  /// actually received rather than on what the engine believes it sent.
  Future<Map<String, dynamic>> serverClicks() async =>
      (await control('/__state'))['clicks'] as Map<String, dynamic>;

  late PortalSyncEngine engine;
  late WebViewController controller;
  final traces = <String>[];

  setUp(() async {
    traces.clear();
    await control('/__reset');
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    engine = PortalSyncEngine(controller);
    PortalSyncEngine.trace = traces.add;
    await controller.setNavigationDelegate(
      NavigationDelegate(onPageFinished: (_) => engine.notifyPageFinished()),
    );
  });

  tearDown(() => PortalSyncEngine.trace = null);

  /// Load [url] and wait until the WebView says it has finished.
  Future<void> load(String url) async {
    final done = Completer<void>();
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        engine.notifyPageFinished();
        if (!done.isCompleted) done.complete();
      },
    ));
    await controller.loadRequest(Uri.parse(url));
    await done.future.timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  /// Log in on the mock (it accepts anything) and land on the dashboard.
  Future<void> logIn() async {
    await load('$base/');
    expect(
        PortalDom.classify(await engine.currentPageHtml()), PortalScreen.login);
    await controller.runJavaScript(
        "document.querySelector('${PortalDom.loginButton.split(',').first}')"
        '.click();');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(PortalDom.classify(await engine.currentPageHtml()),
        PortalScreen.dashboard);
  }

  group('the walk to the account list', () {
    testWidgets('two hops through the empty middle screen, and no more',
        (_) async {
      await logIn();

      final r = await engine.navigateToAccountListDetailed();

      expect(r.reached, isTrue, reason: traces.join('\n'));
      expect(r.failure, NavFailure.none);
      final clicks = await serverClicks();
      // The portal's own count. Two hops is the whole path: the dashboard has
      // no Enquire link, and AgentAccountHomePage is where it appears.
      expect(clicks['accounts'], 1);
      expect(clicks['enquire'], 1);
      expect(traces.any((t) => t.contains('on accountsHome')), isTrue,
          reason: 'the empty middle screen must be recognised, not re-clicked');
    });

    testWidgets('a dropped Enquire click does not become a storm', (_) async {
      await logIn();
      // Swallow the click that would leave the Accounts home screen.
      await control('/__arm?fault=drop&at=1');

      await engine.navigateToAccountListDetailed(
          stepTimeout: const Duration(seconds: 20));

      final clicks = await serverClicks();
      final total = (clicks['accounts'] as int) + (clicks['enquire'] as int);
      // Finacle reads a burst of posts on one link as a replay attack. The old
      // engine measured 20 clicks in 5.6s here.
      expect(total, lessThanOrEqualTo(4), reason: traces.join('\n'));
    });
  });

  group('the full page walk', () {
    testWidgets('reads every page the portal advertises', (_) async {
      await logIn();
      expect((await engine.navigateToAccountListDetailed()).reached, isTrue);

      final result = await engine.syncAllPages();

      expect(result.error, isNull, reason: traces.join('\n'));
      expect(result.complete, isTrue);
      expect(result.accounts.length + result.matured + result.rejected, 480,
          reason: 'the portal advertises 480 across 48 pages');
      // Serial numbering is what the agent reads off a row to find a customer.
      expect(result.accounts.first.serial, 1);
      expect(result.accounts.map((a) => a.accountNumber).toSet().length,
          result.accounts.length,
          reason: 'no page may be read twice');
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('the keep-alive never fires while the walk owns the page',
        (_) async {
      await logIn();
      expect((await engine.navigateToAccountListDetailed()).reached, isTrue);

      // Hammer it throughout the walk, exactly as the 2-minute timer used to.
      var attempts = 0;
      final pest =
          Stream.periodic(const Duration(milliseconds: 300)).listen((_) async {
        attempts++;
        await engine.keepSessionAlive();
      });
      final result = await engine.syncAllPages();
      await pest.cancel();

      expect(attempts, greaterThan(5), reason: 'the pest must have run');
      // THE BUG. The control is a form submit, so every one of these that got
      // through would post on top of the walk — which is what earned Finacle's
      // double-post banner and then killed the session.
      expect((await serverClicks())['keepalive'], 0,
          reason: 'keep-alive posted during the walk:\n${traces.join('\n')}');
      expect(result.complete, isTrue);
      expect(traces.any((t) => t.contains('keep-alive: DECLINED')), isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('failures the agent must be told the truth about', () {
    testWidgets('a session that dies mid-walk keeps what it read', (_) async {
      await logIn();
      expect((await engine.navigateToAccountListDetailed()).reached, isTrue);
      await control('/__arm?fault=expire&at=3');

      final result = await engine.syncAllPages();

      expect(result.complete, isFalse);
      expect(result.error, contains('Log in again'));
      // A short read is still worth merging — but never as a finished sync,
      // and never with serials, which would renumber the book from a prefix.
      expect(result.accounts, isNotEmpty);
      expect(result.accounts.every((a) => a.serial == 0), isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('the double-post banner is waited out, not clicked through',
        (_) async {
      await logIn();
      expect((await engine.navigateToAccountListDetailed()).reached, isTrue);
      await control('/__arm?fault=busy&at=2');

      final result = await engine.syncAllPages();

      // The banner sits on top of a perfectly good page; the walk should ride
      // through it rather than treating it as a stall or clicking again.
      expect(result.complete, isTrue, reason: traces.join('\n'));
      expect(result.accounts.length + result.matured, 480);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
