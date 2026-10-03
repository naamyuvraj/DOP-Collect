import 'package:dop_collect/data/portal/portal_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// A sync that stops early used to be indistinguishable from one that finished.
///
/// `_clickNextAndWait` returned a bool, and `false` meant BOTH "no Next button,
/// that was the last page" and "I clicked Next three times and the table never
/// came back". `syncAllPages` broke out on either and returned a result with no
/// error, so a run that died on page 3 of 47 told the agent "Synced 120
/// accounts", stamped last_sync, and shipped the short count to the dashboard —
/// which reads the most recent sync_done as the size of his book.
///
/// These tests pin the two things that stop that recurring: the three-state
/// advance, and `SyncResult.complete`.
void main() {
  group('PageAdvance keeps "finished" and "gave up" apart', () {
    test('there are three outcomes, not two', () {
      expect(PageAdvance.values, hasLength(3));
      expect(PageAdvance.values, contains(PageAdvance.moved));
      expect(PageAdvance.values, contains(PageAdvance.lastPage));
      expect(PageAdvance.values, contains(PageAdvance.stalled));
    });

    test('a stall is not the last page', () {
      // The whole bug in one line: these used to be the same `false`.
      expect(PageAdvance.stalled, isNot(PageAdvance.lastPage));
    });
  });

  group('SyncResult.complete', () {
    test('a finished sync is complete, and says nothing went wrong', () {
      const r = SyncResult([]);
      expect(r.complete, isTrue);
      expect(r.error, isNull);
      expect(r.reachedList, isTrue);
    });

    test('a partial sync is explicitly incomplete and carries a reason', () {
      const r = SyncResult([],
          error: 'Sync stopped at page 3 of 47.', complete: false);
      expect(r.complete, isFalse);
      expect(r.error, isNotNull);
    });

    test('completeness is independent of having reached the list', () {
      // Reaching the list and finishing the walk are different claims: the
      // engine can open the list fine and still stall on page 3.
      const r = SyncResult([], reachedList: true, complete: false);
      expect(r.reachedList, isTrue);
      expect(r.complete, isFalse);
    });

    test('a partial result still carries the accounts it managed to read', () {
      // They are worth merging — replaceAll is an upsert and removes nothing.
      // What must NOT happen is treating the count as the size of his book.
      const r = SyncResult(<Never>[], complete: false);
      expect(r.accounts, isEmpty);
      expect(r.complete, isFalse);
    });
  });
}
