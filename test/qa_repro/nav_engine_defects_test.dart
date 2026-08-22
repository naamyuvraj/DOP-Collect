import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'fake_webview.dart';

/// Acceptance tests for the walk from login to the account list.
///
/// These drive the REAL [PortalSyncEngine.navigateToAccountListDetailed]
/// against a scripted portal, so what they measure is the engine's actual
/// control flow. The scripted pages are modelled on the captures in
/// `recon/live/` — in particular the portal's **two-hop** menu, which the
/// earlier fake got wrong by putting the Enquire link on the dashboard.
///
/// Started life as reproductions of defects N1 (click storm) and N2 (a spent
/// session reported as a missing link). Both are fixed, so each now asserts the
/// behaviour rather than documenting the fault.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePortal portal;
  late PortalSyncEngine engine;

  void boot(String html) {
    portal = FakePortal(html);
    WebViewPlatform.instance = FakeWebViewPlatform(portal);
    engine = PortalSyncEngine(WebViewController());
  }

  /// Wire the portal up the way the real one behaves: Accounts opens the
  /// (otherwise empty) AgentAccountHomePage, and only there does Enquire exist.
  void wireHappyPath() {
    portal.onAccountsClick = (p) {
      p.html = accountsHomeHtml;
      engine.notifyPageFinished();
    };
    portal.onEnquireClick = (p) {
      p.html = listPage1Html;
      engine.notifyPageFinished();
    };
  }

  group('happy path (proves the harness is honest)', () {
    test('reaches the list in exactly two clicks — Accounts, then Enquire',
        () async {
      boot(dashboardHtml);
      wireHappyPath();

      final r = await engine.navigateToAccountListDetailed();

      expect(r.reached, isTrue);
      expect(r.failure, NavFailure.none);
      expect(portal.accountsMenuClicks, 1);
      expect(portal.enquireClicks, 1);
      expect(portal.totalClicks, 2,
          reason: 'the portal cooperated; two hops is the whole path');
    });

    test('the empty middle screen is progress, not a failed click', () async {
      // AgentAccountHomePage has no table and no content. The old walk could
      // not tell it apart from a click that went nowhere, so it re-clicked a
      // link it had already used.
      boot(accountsHomeHtml);
      portal.onEnquireClick = (p) {
        p.html = listPage1Html;
        engine.notifyPageFinished();
      };

      final r = await engine.navigateToAccountListDetailed();

      expect(r.reached, isTrue);
      expect(portal.accountsMenuClicks, 0,
          reason: 'the Accounts menu is already open — clicking it again would '
              'throw away the screen we needed');
      expect(portal.enquireClicks, 1);
    });

    test('already on the list: no clicks at all', () async {
      boot(listPage1Html);
      final r = await engine.navigateToAccountListDetailed();
      expect(r.reached, isTrue);
      expect(portal.totalClicks, 0);
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
      portal.onAccountsClick = (p) {
        p.html = accountsHomeHtml;
        engine.notifyPageFinished();
      };
      portal.onEnquireClick = (p) {
        // The link is gone the instant the load begins…
        p.html = '<html><body>loading…</body></html>';
        // …and the list lands later, without another click being possible.
        Future<void>.delayed(const Duration(seconds: 2), () {
          p.html = listPage1Html;
          engine.notifyPageFinished();
        });
      };

      final r = await engine.navigateToAccountListDetailed();

      expect(r.reached, isTrue,
          reason: 'the list did arrive; the engine must not have given up on '
              'it just because there was nothing left to click');
      expect(portal.enquireClicks, 1,
          reason: 'one click was enough — it navigated');
    });
  });

  group('N1 — a silently dropped click must not become a click storm', () {
    test('the portal drops every click: the engine backs off and caps',
        () async {
      boot(dashboardHtml);
      // The exact case portal_sync.dart's own comment describes: "the portal
      // can silently drop the click". Page-finish still fires; the DOM never
      // changes — which is why the old walk's 11s slice never applied and the
      // whole budget went out as rapid-fire clicks.
      portal.onAccountsClick = (p) => engine.notifyPageFinished();
      portal.onEnquireClick = (p) => engine.notifyPageFinished();

      final sw = Stopwatch()..start();
      final r = await engine.navigateToAccountListDetailed(
          stepTimeout: const Duration(seconds: 30));
      sw.stop();

      // ignore: avoid_print
      print('    N1: ${portal.enquireClicks} Enquire clicks, '
          '${portal.accountsMenuClicks} menu clicks, '
          '${portal.totalClicks} total in ${sw.elapsedMilliseconds}ms');

      expect(r.reached, isFalse);
      // ACCEPTANCE: a dropped click must be retried a few times with backoff,
      // not hammered. Finacle treats replayed transaction tokens as an attack,
      // and this traffic shape is the likeliest thing that was poisoning
      // sessions in the first place. Measured at 20 clicks in 5.6s before.
      expect(portal.totalClicks, lessThanOrEqualTo(4),
          reason: 'the walk must cap its clicks and space them out');
      expect(r.hops, lessThanOrEqualTo(4));
      // The budget is spent WAITING now, not clicking, so this test needs a
      // limit above its own 30s stepTimeout. That is the point of the fix: a
      // swallowed click and a slow one are indistinguishable except by
      // waiting, and on the live portal the Accounts → Enquire step was
      // measured taking over 17 seconds. Anything that gives up faster than
      // that gives up on healthy navigations — which is exactly the defect
      // this file was written to catch, in its other direction.
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('backing off never overruns the caller\'s budget', () async {
      boot(dashboardHtml);
      portal.onAccountsClick = (p) => engine.notifyPageFinished();
      portal.onEnquireClick = (p) => engine.notifyPageFinished();

      final sw = Stopwatch()..start();
      await engine.navigateToAccountListDetailed(
          stepTimeout: const Duration(seconds: 5));
      sw.stop();

      // The doubling gap used to be able to sleep straight past the deadline.
      expect(sw.elapsed, lessThan(const Duration(seconds: 12)),
          reason: 'a 5s budget must not become a 50s wait');
    });
  });

  group('N2 — a spent session must not be reported as a missing link', () {
    // navigateToAccountList used to return a bare `false`, indistinguishable
    // from "the link was not found", and _sync() rendered that as "Open
    // Accounts -> Agent Inquire and Update, then tap Sync." — advice that
    // cannot work, because only a fresh login clears a spent token. The agent
    // followed it, failed, and repeated.
    test('an expired session is named as such, and says to log in again',
        () async {
      boot(sessionExpiredHtml);

      final r = await engine.navigateToAccountListDetailed();

      expect(r.reached, isFalse);
      expect(r.failure, NavFailure.sessionExpired);
      expect(r.message, contains('Log in again'));
      expect(portal.totalClicks, 0,
          reason: 'nothing on that page is worth clicking');
    });

    test('the guard page is named, and gives up promptly', () async {
      boot(dashboardHtml);
      portal.onAccountsClick = (p) {
        p.html = blockedHtml;
        engine.notifyPageFinished();
      };

      final sw = Stopwatch()..start();
      final r = await engine.navigateToAccountListDetailed();
      sw.stop();

      expect(r.reached, isFalse);
      expect(r.failure, NavFailure.blocked);
      expect(r.message, contains('Log in again'));
      // The first attempt at capping clicks was reverted partly because it made
      // this case hang for the whole step timeout instead of giving up.
      expect(sw.elapsed, lessThan(const Duration(seconds: 15)),
          reason: 'a dead session is knowable immediately — do not sit on it');
    });

    test('landing back on the login page is not a navigation failure',
        () async {
      boot(loginHtml);
      final r = await engine.navigateToAccountListDetailed();
      expect(r.failure, NavFailure.notLoggedIn);
      expect(r.message, contains('Log in again'));
    });
  });

  group('the double-post banner', () {
    // "You clicked on a link or a button when your previous click was still
    // being processed. System is considering your first request." The portal
    // honoured the FIRST click and the page underneath is the right one, so
    // clicking again is precisely what escalates this into a dead session.
    test('is read as "slow down", and the page under it is still the list',
        () async {
      boot(busyListHtml);

      final r = await engine.navigateToAccountListDetailed();

      expect(r.reached, isTrue,
          reason: 'the banner sits on top of a perfectly good account list');
      expect(portal.totalClicks, 0, reason: 'never click through the banner');
    });
  });

  group('page ownership', () {
    // The keep-alive control is a form submit, so clicking it navigates. Fired
    // while a walk was in flight it raced the walk's own post, and Finacle
    // answered with the double-post banner and then ended the session. That is
    // the "reaches the account list, then says Session expired" report.
    test('keep-alive refuses to fire while the engine is driving the page',
        () async {
      boot(dashboardHtml);
      var drivingDuringWalk = false;
      var keepAliveFired = true;

      portal.onAccountsClick = (p) async {
        drivingDuringWalk = engine.isDriving;
        keepAliveFired = await engine.keepSessionAlive();
        p.html = accountsHomeHtml;
        engine.notifyPageFinished();
      };
      portal.onEnquireClick = (p) {
        p.html = listPage1Html;
        engine.notifyPageFinished();
      };

      final r = await engine.navigateToAccountListDetailed();

      expect(r.reached, isTrue);
      expect(drivingDuringWalk, isTrue);
      expect(keepAliveFired, isFalse,
          reason: 'a post on top of the walk is what kills the session');
    });

    test('the engine is idle again once the walk is over', () async {
      boot(listPage1Html);
      await engine.navigateToAccountListDetailed();
      expect(engine.isDriving, isFalse);
    });
  });
}
