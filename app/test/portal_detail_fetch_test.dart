import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_list_portal.dart';

/// "Get exact details" for ONE account, driven against a portal that behaves.
///
/// The flow is: find the account's page → click its number → parse the detail
/// page → click Finacle's Back to return to the listing. Every step of it had
/// only ever been exercised by hand on a handset.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeListPortal portal;
  late PortalSyncEngine engine;

  void boot(FakeListPortal p) {
    portal = p;
    WebViewPlatform.instance = FakeListPlatform(portal);
    engine = PortalSyncEngine(WebViewController());
    portal.onNavigated = () => engine.notifyPageFinished();
  }

  const fast = Duration(seconds: 2);

  test('a correct serial opens the account in one hop', () async {
    final p = FakeListPortal(pages: 20);
    boot(p);
    final target = p.accountsOn(7)[3]; // row 64 of the book

    final d = await engine.fetchAccountDetail(
      accountNumber: target,
      serialHint: 64,
      pageTimeout: fast,
    );

    expect(d, isNotNull);
    expect(d!.accountNumber, target);
    expect(d.totalDeposit, 60000);
    expect(d.pendingInstallments, 2);
    expect(portal.jumps, [7]);
    expect(portal.nextClicks, 0, reason: 'the hint must not fall back to a scan');
    // And it left the session on the listing, not stranded on the detail page.
    expect(portal.openDetail, isNull);
  });

  test('a stale serial still finds the account', () async {
    final p = FakeListPortal(pages: 20);
    boot(p);
    final target = p.accountsOn(7)[3];

    final d = await engine.fetchAccountDetail(
      accountNumber: target,
      serialHint: 58, // six rows early — page 6
      pageTimeout: fast,
    );

    expect(d, isNotNull);
    expect(d!.accountNumber, target);
  });

  test('no serial at all: the scan finds it', () async {
    final p = FakeListPortal(pages: 6);
    boot(p);
    final target = p.accountsOn(4)[2];

    final d = await engine.fetchAccountDetail(
      accountNumber: target,
      pageTimeout: fast,
    );

    expect(d, isNotNull);
    expect(d!.accountNumber, target);
  });

  test('an account that is not in the book returns null, not a wrong one',
      () async {
    final p = FakeListPortal(pages: 4);
    boot(p);

    final d = await engine.fetchAccountDetail(
      accountNumber: '029999999999',
      serialHint: 12,
      pageTimeout: fast,
    );

    expect(d, isNull);
    expect(portal.openDetail, isNull);
  });

  group('a failure says WHICH failure it was', () {
    test('the stale-token guard is named, not reported as a missing account',
        () async {
      // What a browser Back onto a spent Finacle page earns. It used to come
      // back as a bare null, so the agent was told the ACCOUNT was the problem
      // and went looking for a customer who was never missing.
      final p = FakeListPortal(pages: 4)..blocked = true;
      boot(p);

      String? why;
      final d = await engine.fetchAccountDetail(
        accountNumber: p.accountsOn(2)[0],
        serialHint: 11,
        onDiag: (r) => why = r,
        pageTimeout: fast,
      );

      expect(d, isNull);
      expect(why, contains('blocked'));
      expect(why, contains('log in again'));
    });

    test('an account genuinely off the list says so', () async {
      final p = FakeListPortal(pages: 3);
      boot(p);
      String? why;
      final d = await engine.fetchAccountDetail(
        accountNumber: '029999999999',
        onDiag: (r) => why = r,
        pageTimeout: fast,
      );
      expect(d, isNull);
      expect(why, contains('not on the portal'));
    });
  });

  test('a click that goes nowhere is a miss, not a detail page', () async {
    // The whole-book print preview renders the account numbers as <span>s.
    // click() finds the element and does nothing; the old code called that
    // success, waited out the page timeout, then parsed the LISTING as an
    // account's detail page and saved whatever fell out of it.
    final p = FakeListPortal(pages: 3)..previewMarkup = true;
    boot(p);

    String? why;
    final d = await engine.fetchAccountDetail(
      accountNumber: p.accountsOn(2)[0],
      serialHint: 11,
      onDiag: (r) => why = r,
      pageTimeout: fast,
    );

    expect(d, isNull, reason: 'never invent a detail from the listing');
    expect(why, isNotNull);
  });

  test('a detail page with no readable fields is not saved as data', () async {
    final p = FakeListPortal(pages: 4);
    boot(p);
    final target = p.accountsOn(2)[0];
    p.blankDetail.add(target);

    final d = await engine.fetchAccountDetail(
      accountNumber: target,
      serialHint: 11,
      pageTimeout: fast,
    );

    expect(d, isNull, reason: 'nothing parsed means nothing to write');
  });
}
