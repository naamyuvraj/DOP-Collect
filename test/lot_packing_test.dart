import 'package:dop_collect/models/lot_packing.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';

RdAccount _acct(String n, int denom, DateTime due,
        {CollectionStatus status = CollectionStatus.pending}) =>
    RdAccount(
      accountNumber: n,
      customerName: 'C$n',
      denominationAmount: denom,
      nextDueDate: due,
      monthsPaid: 10,
      status: status,
    );

void main() {
  final now = DateTime(2026, 7, 15);

  test('packs eligible accounts into ₹20k-capped lots', () {
    final accounts = [
      _acct('1', 10000, DateTime(2026, 7, 5)), // due this month
      _acct('2', 10000, DateTime(2026, 7, 8)),
      _acct('3', 5000, DateTime(2026, 7, 10)),
    ];
    final lots = LotPacking.pack(accounts, now, cap: 20000);
    // 10000 + 10000 = 20000 fills lot 1; 5000 starts lot 2.
    expect(lots.length, 2);
    expect(lots[0].totalAmount, 20000);
    expect(lots[0].count, 2);
    expect(lots[1].totalAmount, 5000);
    for (final lot in lots) {
      expect(lot.totalAmount <= 20000, isTrue);
    }
  });

  test('eligible excludes paid-ahead and already-collected accounts', () {
    final accounts = [
      _acct('due', 2000, DateTime(2026, 7, 2)), // behind 0 -> eligible
      _acct('ahead', 2000, DateTime(2026, 9, 2)), // paid ahead -> excluded
      _acct('done', 2000, DateTime(2026, 7, 2),
          status: CollectionStatus.deposited), // collected -> excluded
      _acct('late', 2000, DateTime(2026, 4, 2)), // overdue -> eligible, first
    ];
    final eligible = LotPacking.eligible(accounts, now);
    // Reliable (due this month) ranks ahead of overdue now.
    expect(eligible.map((a) => a.accountNumber), ['due', 'late']);
  });

  test('reliable (on-time) account is packed before an overdue one', () {
    final accounts = [
      _acct('overdue', 2000, DateTime(2026, 1, 2)), // most behind
      _acct('current', 2000, DateTime(2026, 7, 2)), // due this month
    ];
    final lots = LotPacking.build(accounts, now);
    expect(lots.first.items.first.accountNumber, 'current');
  });

  test('one installment per account', () {
    final lots = LotPacking.build(
        [_acct('1', 3000, DateTime(2026, 7, 2))], now);
    expect(lots.single.items.single.installments, 1);
    expect(lots.single.totalAmount, 3000);
  });
}
