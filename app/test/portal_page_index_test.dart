import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_list_portal.dart';

/// The page index — `serial` — and the jump it pays for.
///
/// Building a list means ticking nine accounts scattered over ~48 portal pages.
/// Rather than walk all of them, the app remembers each account's row position
/// from the last sync and jumps straight to `(serial - 1) ~/ rowsPerPage + 1`.
///
/// That only works while `serial` is the row's TRUE position in the listing.
/// Sync used to number the accounts it kept, 1..N — but the portal also renders
/// rows that never become accounts: a matured account (blank due date) and an
/// unreadable row both hold a position without reaching the book. Three such
/// rows near the top of the listing shifted every account after them three rows
/// early, which lands ~30% of jumps on the page BEFORE the account. Each miss
/// falls through to the correctness net: a full sequential scan. The index was
/// still there, it just stopped saving anything.
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

  group('serial is the row position, not the count of kept rows', () {
    test('rows that never become accounts still hold their place', () async {
      // Page 1: rows 1-2 unreadable, rows 3-4 matured, rows 5-10 real accounts.
      boot(FakeListPortal(pages: 3)
        ..unreadableRowsOnPage[1] = 2
        ..maturedRowsOnPage[1] = 2);
      final r = await engine.syncAllPages(pageTimeout: fast);

      expect(r.complete, isTrue);
      expect(r.rejected, 2);
      expect(r.maturedRows, hasLength(2));

      // The first account the app keeps sits in row 5 of the portal, and says
      // so. Numbering the kept rows would have called it #1.
      expect(r.accounts.first.accountNumber, portal.accountsOn(1)[4]);
      expect(r.accounts.first.serial, 5);

      // And the offset does not accumulate down the book: the first row of
      // page 2 is row 11 whatever page 1 held.
      final firstOfPage2 =
          r.accounts.firstWhere((a) => a.accountNumber == portal.accountsOn(2)[0]);
      expect(firstOfPage2.serial, 11);
      expect(r.accounts.last.serial, 30);
    });

    test('a clean book is still numbered 1..N', () async {
      boot(FakeListPortal(pages: 3));
      final r = await engine.syncAllPages(pageTimeout: fast);
      expect(r.accounts.map((a) => a.serial).toList(),
          List.generate(30, (i) => i + 1));
    });
  });

  group('a list build jumps straight to the page', () {
    /// Sync, then prepare a list of accounts spread across the book, exactly as
    /// `_prepareOnPortal` does — the serials handed to [prepareList] are the
    /// ones sync just wrote.
    Future<ListPrepResult> syncThenPrepare(
      FakeListPortal p,
      List<String> wanted,
    ) async {
      boot(p);
      final synced = await engine.syncAllPages(pageTimeout: fast);
      expect(synced.complete, isTrue);
      final serials = {
        for (final a in synced.accounts)
          if (a.serial > 0) a.accountNumber: a.serial,
      };
      portal.jumps.clear();
      portal.nextClicks = 0;
      return engine.prepareList(
        accountNumbers: wanted.toSet(),
        mode: 'C',
        serialByAccount: serials,
        pageTimeout: fast,
      );
    }

    test('one jump per page, and no sequential scan', () async {
      final p = FakeListPortal(pages: 20)
        // The maturities that used to poison the arithmetic.
        ..maturedRowsOnPage[1] = 3;
      // One account from the first row of pages 4, 11 and 18 — the positions
      // the three-row drift used to push onto the previous page.
      final wanted = [
        p.accountsOn(4)[0],
        p.accountsOn(11)[0],
        p.accountsOn(18)[0],
      ];

      final r = await syncThenPrepare(p, wanted);

      expect(r.error, isNull);
      expect(r.saved, isTrue);
      expect(r.selected, wanted.toSet());
      expect(r.missing(wanted.toSet()), isEmpty);

      // The point of the whole exercise: three targets, three jumps, and the
      // 20-page fallback scan never ran.
      expect(portal.jumps, [4, 11, 18]);
      expect(portal.nextClicks, 0,
          reason: 'a Next click here means the fast path missed');
    });

    test('a stale index costs a handful of jumps, not the whole walk', () async {
      // Six accounts opened since the last sync, all near the front — every
      // account after them has moved most of a page. The old fallback was the
      // full 40-page walk for each one; the probe halves the book instead.
      final p = FakeListPortal(pages: 40);
      boot(p);
      // Rows 83 and 258 of the book — page 9 and page 26.
      const rows = {83: 9, 258: 26};
      final wanted = [
        for (final row in rows.keys) p.accountsOn(rows[row]!)[(row - 1) % 10],
      ];
      // What the last sync recorded: six rows short, so both point a page early.
      final stale = {
        for (var i = 0; i < wanted.length; i++)
          wanted[i]: rows.keys.elementAt(i) - 6,
      };

      final r = await engine.prepareList(
        accountNumbers: wanted.toSet(),
        mode: 'C',
        serialByAccount: stale,
        pageTimeout: fast,
      );

      expect(r.selected, wanted.toSet());
      expect(portal.nextClicks, 0, reason: 'the 40-page scan must not run');
      // Two indexed jumps that miss, then a binary search over 40 pages.
      expect(portal.jumps.length, lessThan(20));
    });

    test('the short account numbers at the end of the book are handled',
        () async {
      // The live book holds 468 twelve-digit accounts and then 11 ten-digit
      // ones, which the portal sorts last because that is where string order
      // puts them. Ordering them any other way makes the probe call the book
      // unsorted and hand the whole thing to the scan.
      final p = FakeListPortal(pages: 12)
        ..renumber[12] = {
          for (var i = 0; i < 10; i++) i: '47836913${(60 + i).toString()}',
        };
      boot(p);
      final target = p.accountsOn(12)[6];
      expect(target.length, 10);

      final r = await engine.prepareList(
        accountNumbers: {target},
        mode: 'C',
        serialByAccount: const {},
        pageTimeout: fast,
      );

      expect(r.selected, {target});
      expect(portal.nextClicks, 0, reason: 'the book IS in portal order');
    });

    test('a listing sorted by something else falls back to the scan', () async {
      // The agent clicked a column header, so account numbers are no longer in
      // order. Halving the book would follow that order off a cliff; the probe
      // has to notice and stand down.
      final p = FakeListPortal(pages: 8)
        ..renumber[4] = {0: '029999999999', 1: '020000000001'};
      boot(p);
      final target = p.accountsOn(7)[5];

      final r = await engine.prepareList(
        accountNumbers: {target},
        mode: 'C',
        // A serial that points at page 1 — wrong, so the probe gets its turn.
        serialByAccount: {target: 3},
        pageTimeout: fast,
      );

      expect(r.selected, {target}, reason: 'the scan is the net, always');
      expect(portal.nextClicks, greaterThan(0));
    });

    test('an account with no index at all is still placed by halving',
        () async {
      // Never synced, or closed and reopened — no serial to jump by. The probe
      // does not need one; the order of the book is enough.
      final p = FakeListPortal(pages: 32);
      boot(p);
      final target = p.accountsOn(29)[3];
      final r = await engine.prepareList(
        accountNumbers: {target},
        mode: 'C',
        serialByAccount: const {},
        pageTimeout: fast,
      );
      expect(r.selected, {target});
      expect(portal.nextClicks, 0);
      expect(portal.jumps.length, lessThanOrEqualTo(6),
          reason: 'log2(32) jumps, not 32 pages');
    });
  });
}
