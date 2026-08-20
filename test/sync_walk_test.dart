import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_list_portal.dart';

/// The page walk, driven for real against a portal that misbehaves.
///
/// `sync_completeness_test.dart` pins the SHAPE of the result — three advance
/// states, a `complete` flag. Nothing pinned the walk that sets them, and that
/// is where the damage was: `_clickNextAndWait` declared success as soon as an
/// account table was on screen, and the page it was already showing has one.
/// A portal that swallowed a Next click therefore read as a successful move.
/// Accounts de-duplicate by number, so re-reading page 1 forty-seven times
/// added nothing, raised no error, and returned `complete: true` holding ten
/// accounts — at which point `replaceAll` closed the other 455.
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

  group('a walk that really reads every page', () {
    test('is complete, and holds the whole book', () async {
      boot(FakeListPortal(pages: 5));
      final r = await engine.syncAllPages(pageTimeout: fast);

      expect(r.error, isNull);
      expect(r.complete, isTrue);
      expect(r.accounts, hasLength(50));
      expect(r.rejected, 0);
      // Serials are 1..N in portal order — the short codes he reads off a row.
      expect(r.accounts.first.serial, 1);
      expect(r.accounts.last.serial, 50);
    });
  });

  group('a portal that swallows the Next click', () {
    test('is NOT reported as a finished sync', () async {
      boot(FakeListPortal(pages: 12)..dropNextOnPage.add(1));
      final r = await engine.syncAllPages(pageTimeout: fast);

      expect(r.complete, isFalse,
          reason: 'the walk never left page 1; it cannot be complete');
      expect(r.error, isNotNull);
      expect(r.accounts, hasLength(10), reason: 'one page was genuinely read');
    });

    test('and so it closes nothing — the whole point', () async {
      final repo = MemoryAccountRepository();
      final full = FakeListPortal(pages: 12);
      boot(full);
      final good = await engine.syncAllPages(pageTimeout: fast);
      await repo.replaceAll(good.accounts, complete: good.complete);
      expect(await repo.count(), 120);

      // Now the same portal, dropping the click off page 1.
      boot(FakeListPortal(pages: 12)..dropNextOnPage.add(1));
      final bad = await engine.syncAllPages(pageTimeout: fast);
      final merge =
          await repo.replaceAll(bad.accounts, complete: bad.complete);

      expect(merge.closed, isEmpty);
      expect(merge.refused, isFalse);
      expect(await repo.count(), 120, reason: 'the book is untouched');
    });

    test('a short read never renumbers the book', () async {
      boot(FakeListPortal(pages: 12)..dropNextOnPage.add(1));
      final r = await engine.syncAllPages(pageTimeout: fast);
      // Serial 0 means "keep whatever this account already had". Numbering a
      // prefix 1..10 would give ten live accounts a second, colliding code.
      expect(r.accounts.every((a) => a.serial == 0), isTrue);
    });
  });

  group('a page that renders no rows', () {
    test('is a portal that has not finished loading, not an empty page',
        () async {
      boot(FakeListPortal(pages: 5)..blankPages.add(3));
      final r = await engine.syncAllPages(pageTimeout: fast);

      expect(r.complete, isFalse);
      expect(r.error, contains('came back empty'));
      expect(r.accounts, hasLength(20), reason: 'pages 1 and 2 were real');
    });
  });

  group('rows the parser cannot read', () {
    test('are dropped and counted, never stored as a sentinel date', () async {
      boot(FakeListPortal(pages: 2)..unreadableRowsOnPage[1] = 3);
      final r = await engine.syncAllPages(pageTimeout: fast);

      expect(r.complete, isTrue);
      expect(r.rejected, 3);
      expect(r.accounts, hasLength(17));
      // The sentinel was DateTime(2000) — ~320 months overdue, which put the
      // account in Defaulters and added ~Rs 3.2 lakh to the To Collect total.
      expect(r.accounts.every((a) => a.nextDueDate.year > 2000), isTrue);
    });
  });

  group('the closure guard', () {
    test('refuses a mass closure even if a walk claims to be complete',
        () async {
      final repo = MemoryAccountRepository();
      boot(FakeListPortal(pages: 12));
      final full = await engine.syncAllPages(pageTimeout: fast);
      await repo.replaceAll(full.accounts, complete: true);
      expect(await repo.count(), 120);

      // A one-page book, asserted complete — what the old walk produced.
      boot(FakeListPortal(pages: 1));
      final one = await engine.syncAllPages(pageTimeout: fast);
      expect(one.complete, isTrue, reason: 'one page IS the whole listing here');

      final merge = await repo.replaceAll(one.accounts, complete: true);
      expect(merge.refused, isTrue);
      expect(merge.refusedClosures, 110);
      expect(merge.closed, isEmpty);
      expect(await repo.count(), 120, reason: 'nobody left the book');
    });

    test('a normal month of maturities still closes', () async {
      final repo = MemoryAccountRepository();
      boot(FakeListPortal(pages: 12));
      final full = await engine.syncAllPages(pageTimeout: fast);
      await repo.replaceAll(full.accounts, complete: true);

      // 8 accounts matured — inside the ceiling for a 120-account book.
      final survivors = full.accounts.take(112).toList();
      final merge = await repo.replaceAll(survivors, complete: true);

      expect(merge.refused, isFalse);
      expect(merge.closed, hasLength(8));
      expect(await repo.count(), 112);
    });
  });
}
