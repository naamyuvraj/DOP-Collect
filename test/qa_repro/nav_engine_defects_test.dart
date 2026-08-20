import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'fake_webview.dart';

/// QA reproductions for the "logged in but it never opens Accounts" reports.
///
/// These drive the REAL [PortalSyncEngine.navigateToAccountList] against a
/// scripted portal, so what they measure is the engine's actual control flow.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePortal portal;
  late PortalSyncEngine engine;

  void boot(String html) {
    portal = FakePortal(html);
    WebViewPlatform.instance = FakeWebViewPlatform(portal);
    engine = PortalSyncEngine(WebViewController());
  }

  group('happy path (proves the harness is honest)', () {
    test('a click that really navigates reaches the list on the first hop',
        () async {
      boot(dashboardHtml);
      portal.onEnquireClick = (p) {
        p.html = listPage1Html;
        engine.notifyPageFinished();
      };
      expect(await engine.navigateToAccountList(), isTrue);
      expect(portal.enquireClicks, 1,
          reason: 'one click should be enough when the portal cooperates');
    });
  });

  group('the link vanishes into its own navigation', () {
    // The field report: "could not open account list… but at that time it has
    // been already opened and the process is stopped". The click LANDS, the
    // Enquire link leaves the DOM because the load has started, and the list
    // paints a moment later. The engine used to read "nothing to click" as
    // "nowhere to go", break, and answer false while the page was still on its
    // way — so the message and the list arrived together.
    test('a slow navigation is waited out, not called a dead end', () async {
      boot(dashboardHtml);
      portal.onEnquireClick = (p) {
        // The link is gone the instant the load begins…
        p.html = '<html><body>loading…</body></html>';
        // …and the list lands later, without another click being possible.
        Future<void>.delayed(const Duration(seconds: 2), () {
          p.html = listPage1Html;
          engine.notifyPageFinished();
        });
      };
      expect(await engine.navigateToAccountList(), isTrue,
          reason: 'the list did arrive; the engine must not have given up on '
              'it just because there was nothing left to click');
      expect(portal.enquireClicks, 1,
          reason: 'one click was enough — it navigated');
    });
  });

  group('DEFECT N1 — a silently dropped click becomes a click storm', () {
    test('the portal drops every click: how many does the engine fire?',
        () async {
      boot(dashboardHtml);
      // The exact case portal_sync.dart's own comment describes: "the portal can
      // silently drop the click". Page-finish still fires; the DOM never changes.
      portal.onEnquireClick = (p) => engine.notifyPageFinished();

      final sw = Stopwatch()..start();
      final ok = await engine.navigateToAccountList();
      sw.stop();

      expect(ok, isFalse);
      // ignore: avoid_print
      print('    N1: ${portal.enquireClicks} Enquire clicks, '
          '${portal.accountsMenuClicks} menu clicks, '
          '${portal.totalClicks} total in ${sw.elapsedMilliseconds}ms');

      // ACCEPTANCE: a dropped click must be retried a few times with backoff,
      // not hammered. Finacle treats replayed transaction tokens as an attack.
      expect(portal.totalClicks, lessThanOrEqualTo(4),
          reason: 'DEFECT N1: the engine re-clicks the same link on every '
              'slice of every hop with no backoff and no cap');
    }, skip: 'DEFECT N1 — un-skip when navigateToAccountList backs off. A '
        'first attempt (capped clicks + backoff) made the guard-page case hang '
        'for the whole step timeout instead of giving up quietly, and could '
        'not be verified against the real portal, so it was reverted.');
  });

  // NOTE (QA): the guard-page path was measured, NOT stormed — the engine
  // issues exactly ONE Enquire click and then exits, because the guard page has
  // no Enquire link to find. The defect there is not thrash, it is DIAGNOSIS:
  // navigateToAccountList returns a bare `false`, and _sync() renders that as
  // "Open Accounts -> Agent Inquire and Update, then tap Sync" — which cannot
  // work, since only a fresh login clears a spent token. Asserting the fix needs
  // an API that does not exist yet (a failure reason), so N2 is carried in the
  // report as an inspection finding with the EVIDENCE test below as its record.

  group('EVIDENCE — measurements the engineer will want (always run)', () {
    test('dropped-click storm: click count and wall clock', () async {
      boot(dashboardHtml);
      portal.onEnquireClick = (p) => engine.notifyPageFinished();
      final sw = Stopwatch()..start();
      await engine.navigateToAccountList();
      sw.stop();
      // ignore: avoid_print
      print('    EVIDENCE N1: totalClicks=${portal.totalClicks} '
          'elapsed=${sw.elapsedMilliseconds}ms');
      expect(portal.totalClicks, greaterThan(4),
          reason: 'documents the storm; delete when N1 is fixed');
    });

    test('guard page: engine gives up quietly, no blocked-page probe is issued',
        () async {
      boot(dashboardHtml);
      portal.onEnquireClick = (p) {
        p.html = blockedHtml;
        engine.notifyPageFinished();
      };
      await engine.navigateToAccountList();
      final probedHtml =
          portal.injected.where((j) => j.contains('outerHTML')).length;
      // ignore: avoid_print
      print('    EVIDENCE N2: ${portal.injected.length} scripts injected, '
          '$probedHtml DOM reads, enquireClicks=${portal.enquireClicks}');
      expect(probedHtml, greaterThan(0));
    });
  });
}
