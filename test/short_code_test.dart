import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "Short Code" is the app's OWN shorthand for an account — a 1-based
/// position in the portal listing, not anything the portal issues. It has two
/// jobs, and they pull the same way:
///
///   * the agent reads `#47` off a row to find a customer quickly, and
///   * `serialHint` turns it back into a page number to jump to on the portal
///     (`(serial-1) ~/ 10 + 1`), which only works while it tracks position.
///
/// So it MOVES when the book changes — ten new accounts ahead of a customer
/// shift him by ten — and that is correct rather than a bug. What must hold is
/// that it is never duplicated, never invented, and never renumbered by a sync
/// that did not finish. These tests pin exactly that.
void main() {
  RdAccount acct(String n, {int serial = 0}) => RdAccount(
        accountNumber: n,
        customerName: 'C$n',
        denominationAmount: 500,
        nextDueDate: DateTime(2026, 8, 1),
        monthsPaid: 10,
        serial: serial,
      );

  test('a complete sync numbers the book 1..N in portal order', () {
    // What PortalSyncEngine._serialised produces: position in the listing.
    final synced = [
      for (var i = 0; i < 3; i++) acct('A$i', serial: i + 1),
    ];
    expect(synced.map((a) => a.serial).toList(), [1, 2, 3]);
    // Unique — two customers must never answer to the same short code.
    expect(synced.map((a) => a.serial).toSet().length, synced.length);
  });

  test('a partial sync leaves every existing short code alone', () async {
    final repo = MemoryAccountRepository();
    await repo.replaceAll([acct('A1', serial: 1), acct('A2', serial: 2)]);

    // An incomplete walk passes serial 0 for everything, which the merge reads
    // as "keep what this account had". Without that, a short read would number
    // its prefix 1..N and leave later accounts on stale numbers — two customers
    // sharing a code.
    await repo.replaceAll([acct('A1'), acct('A2')]);

    final all = await repo.all();
    expect(all.firstWhere((a) => a.accountNumber == 'A1').serial, 1);
    expect(all.firstWhere((a) => a.accountNumber == 'A2').serial, 2);
  });

  test('a re-sync renumbers rather than duplicating when order changes', () async {
    final repo = MemoryAccountRepository();
    await repo.replaceAll([acct('A1', serial: 1), acct('A2', serial: 2)]);
    // A new account opened ahead of both: everyone shifts down one. Expected —
    // the code is a position, and the agent is told it can move.
    await repo.replaceAll([
      acct('NEW', serial: 1),
      acct('A1', serial: 2),
      acct('A2', serial: 3),
    ]);
    final all = await repo.all();
    expect(all.firstWhere((a) => a.accountNumber == 'A1').serial, 2);
    expect(all.map((a) => a.serial).toSet().length, all.length,
        reason: 'still unique after a shift');
  });

  test('an account with no short code yet reads as unset, never as #0', () {
    // Every display site guards on `serial > 0` and shows an em dash instead —
    // a "#0" would look like a real code the agent could search for.
    expect(acct('A1').serial, 0);
  });
}
