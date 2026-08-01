import 'package:flutter_test/flutter_test.dart';

import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/portal/agent_detail_parser.dart';
import 'package:dop_collect/models/rd_account.dart';

/// B2 regression: a re-sync must MERGE, never wipe. Collection marks and Deep
/// Sync detail the portal list doesn't carry have to survive the next sync, and
/// an account missing from a (partial) sync must not vanish.
void main() {
  RdAccount base(String acct, {int monthsPaid = 10, int serial = 0}) =>
      RdAccount(
        accountNumber: acct,
        customerName: 'CUST $acct',
        denominationAmount: 1000,
        nextDueDate: DateTime(2026, 8, 1),
        monthsPaid: monthsPaid,
        serial: serial,
      );

  test('re-sync preserves status, detail and serial; updates core fields',
      () async {
    final repo = MemoryAccountRepository();

    // First sync brings the account in.
    await repo.replaceAll([base('A1', monthsPaid: 10, serial: 7)]);

    // Local state accrues: marked deposited + Deep Sync detail filled.
    await repo.setStatus('A1', CollectionStatus.deposited);
    await repo.applyDetail(AccountDetail(
      accountNumber: 'A1',
      totalDeposit: 12345,
      lastDepositDate: DateTime(2026, 7, 20),
    ));

    // Next portal list sync: fresh parse (no status, no serial, no detail) but
    // an updated months-paid.
    await repo.replaceAll([base('A1', monthsPaid: 11, serial: 0)]);

    final a = await repo.byAccountNumber('A1');
    expect(a, isNotNull);
    // Core field updated from the portal.
    expect(a!.monthsPaid, 11);
    // Local state preserved.
    expect(a.status, CollectionStatus.deposited);
    expect(a.totalDeposit, 12345);
    expect(a.lastDepositDate, DateTime(2026, 7, 20));
    // Serial kept when the fresh parse didn't set one.
    expect(a.serial, 7);
  });

  test('accounts absent from a partial sync are not deleted', () async {
    final repo = MemoryAccountRepository();
    await repo.replaceAll([base('A1'), base('A2')]);

    // A partial sync returns only A1.
    await repo.replaceAll([base('A1')]);

    expect(await repo.byAccountNumber('A2'), isNotNull);
    expect(await repo.count(), 2);
  });
}
