import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';

/// An RD account that matures and closes just stops appearing in the portal's
/// "Agent Inquire and Update" listing — there is no status column and no
/// closure event to read. So absence from a sync that read EVERY page is the
/// only closure signal that exists.
///
/// It used to be thrown away: `replaceAll` was an upsert and nothing else ever
/// removed a row, so a closed account stayed in the book for good. It then aged
/// into a permanent defaulter (its next due date receding a month at a time,
/// its "arrears" growing by a full installment every month), kept its old short
/// code while a complete sync renumbered the live book around it, and sat in
/// the daily round for a customer who no longer had an account.
///
/// These tests pin the fix and — just as importantly — the caution it must not
/// lose: absence only means something when the walk actually finished.
void main() {
  RdAccount acct(String n, {int serial = 0, String name = ''}) => RdAccount(
        accountNumber: n,
        customerName: name.isEmpty ? 'C$n' : name,
        denominationAmount: 500,
        nextDueDate: DateTime(2026, 8, 1),
        monthsPaid: 10,
        serial: serial,
      );

  group('a complete sync is what closes an account', () {
    test('an account missing from a finished sync is closed and leaves the book',
        () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);

      // A2 matured and closed, so the portal no longer lists it.
      final closed = await repo.replaceAll([acct('A1')], complete: true);

      expect(closed.map((a) => a.accountNumber), ['A2']);
      // Gone from every surface that asks about the live book.
      expect((await repo.all()).map((a) => a.accountNumber), ['A1']);
      expect(await repo.search('C'), hasLength(1));
      expect(await repo.count(), 1);
    });

    test('the closed row is kept, because its khata holds real money', () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);
      await repo.replaceAll([acct('A1')], complete: true);

      // `collections` rows point at this account number. Deleting it would
      // leave the agent with payments he made against no name at all.
      final a2 = await repo.byAccountNumber('A2');
      expect(a2, isNotNull);
      expect(a2!.isClosed, isTrue);
      expect(a2.closedAt, isNotNull);
    });

    test('closing drops the short code so it cannot collide with a live one',
        () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1', serial: 1), acct('A2', serial: 2)],
          complete: true);

      // A1 closes; the portal now lists A2 first, so a complete sync renumbers
      // it to #1 — the number A1 was still holding.
      await repo.replaceAll([acct('A2', serial: 1)], complete: true);

      expect((await repo.byAccountNumber('A1'))!.serial, 0,
          reason: 'a closed account must not answer to a live short code');
      expect((await repo.byAccountNumber('A2'))!.serial, 1);
    });
  });

  group('a sync that did not finish closes nothing', () {
    test('an account missing from a partial sync is left completely alone',
        () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);

      // A stalled walk holds only a PREFIX of the book. Reading absence there
      // as closure would close almost everyone.
      final closed = await repo.replaceAll([acct('A1')]);

      expect(closed, isEmpty);
      expect(await repo.count(), 2);
      expect((await repo.byAccountNumber('A2'))!.isClosed, isFalse);
    });

    test('the default is the safe one — a caller must OPT IN to closing',
        () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')]);
      await repo.replaceAll([acct('A1')]); // no `complete:` at all
      expect(await repo.count(), 2);
    });
  });

  group('a closure is reversible', () {
    test('an account that reappears on the portal is live again', () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);
      await repo.replaceAll([acct('A1')], complete: true);
      expect((await repo.byAccountNumber('A2'))!.isClosed, isTrue);

      // The portal briefly dropped a row, or the account was reopened at the
      // counter. Either way, being listed means live — a wrong closure must
      // cost the agent one sync, never a customer.
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);

      expect((await repo.byAccountNumber('A2'))!.isClosed, isFalse);
      expect(await repo.count(), 2);
    });

    test('a later sync does not re-stamp an already-closed account', () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);
      await repo.replaceAll([acct('A1')], complete: true);
      final firstStamp = (await repo.byAccountNumber('A2'))!.closedAt;

      // Every sync from here on also fails to see A2. If each one refreshed the
      // date, the account would never age out of Matured Accounts — the
      // one-month window would restart on every sync, forever.
      final again = await repo.replaceAll([acct('A1')], complete: true);

      expect(again, isEmpty, reason: 'it closed once; it is not news twice');
      expect((await repo.byAccountNumber('A2'))!.closedAt, firstStamp);
    });
  });

  group('the one-month window', () {
    test('is exactly one calendar month back, not thirty days', () {
      expect(maturedFrom(DateTime(2026, 8, 19)), DateTime(2026, 7, 19));
      // Across a year boundary.
      expect(maturedFrom(DateTime(2026, 1, 5)), DateTime(2025, 12, 5));
      // A short month: DateTime normalises the overflow (31 Mar - 1 month is
      // read as 3 Mar), which shows the account a day or two LONGER. That is
      // the harmless direction — the alternative hides it early.
      expect(maturedFrom(DateTime(2026, 3, 31)), DateTime(2026, 3, 3));
    });

    test('lists recent closures, newest first, and nothing else', () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      await repo.replaceAll([acct('A1')], complete: true);

      expect((await repo.maturedSince(before)).map((a) => a.accountNumber),
          ['A2']);
      // A live account is never in this list, however overdue it is.
      expect((await repo.maturedSince(before)).any((a) => a.accountNumber == 'A1'),
          isFalse);
    });

    test('drops an account once the window has passed it', () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([acct('A1'), acct('A2')], complete: true);
      await repo.replaceAll([acct('A1')], complete: true);

      // A window that starts after the closure — i.e. a month has gone by. The
      // row still exists (the khata needs it); it just stops being listed.
      final after = DateTime.now().add(const Duration(seconds: 1));
      expect(await repo.maturedSince(after), isEmpty);
      expect(await repo.byAccountNumber('A2'), isNotNull);
    });
  });
}
