import 'package:dop_collect/models/lot.dart';
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

  test('eligible excludes paid-ahead and accounts already listed this cycle',
      () {
    final accounts = [
      _acct('due', 2000, DateTime(2026, 7, 2)), // behind 0 -> eligible
      _acct('ahead', 2000, DateTime(2026, 9, 2)), // paid ahead -> excluded
      _acct('done', 2000, DateTime(2026, 7, 2)), // on a list -> excluded
      _acct('late', 2000, DateTime(2026, 4, 2)), // overdue -> eligible, first
    ];
    final eligible =
        LotPacking.eligible(accounts, now, alreadyListed: {'done'});
    // Reliable (due this month) ranks ahead of overdue now.
    expect(eligible.map((a) => a.accountNumber), ['due', 'late']);
  });

  group('the listed-this-cycle guard expires with the cycle', () {
    // `submitted` is not decoration: an unsubmitted list blocks its accounts
    // for ever, and only a FILED one expires with its cycle. See
    // LotPacking._stillBlocks.
    Lot lotOn(DateTime created, String account, {bool submitted = false}) => Lot(
          createdAt: created,
          mode: 'Cash',
          referenceNumber: submitted ? 'C123456789' : null,
          submittedAt: submitted ? created : null,
          items: [
            LotItem(
              accountNumber: account,
              customerName: 'C$account',
              denomination: 2000,
              installments: 1,
            ),
          ],
        );

    test('a list built this month keeps its accounts out of auto-build', () {
      final listed = LotPacking.listedThisCycle(
          [lotOn(DateTime(2026, 7, 3), 'a')], now);
      expect(listed, {'a'});
    });

    test('last month\'s SUBMITTED list does not suppress this month', () {
      // The regression that mattered: the old `status == deposited` flag was
      // never reset, so every customer collected in June stayed invisible to
      // auto-build in July, August and forever. Derived from the lists, June's
      // list stops counting once July starts — but only because the cash was
      // actually handed in, which is what `submitted` says here.
      final june = [lotOn(DateTime(2026, 6, 3), 'a', submitted: true)];
      expect(LotPacking.listedThisCycle(june, now), isEmpty);

      final accounts = [_acct('a', 2000, DateTime(2026, 7, 2))];
      final lots = LotPacking.build(accounts, now,
          alreadyListed: LotPacking.listedThisCycle(june, now));
      expect(lots.single.items.single.accountNumber, 'a');
    });

    test('an UNSUBMITTED list from last month still blocks', () {
      // The other half of the rule, and the reason it exists: a list built on
      // 31 July and still sitting unsubmitted on 1 August is a live claim on
      // those accounts. Expiring it by the calendar let auto-build pack the
      // same customers a second time while the first list waited to be filed.
      final june = [lotOn(DateTime(2026, 6, 3), 'a')];
      expect(LotPacking.listedThisCycle(june, now), {'a'});

      final accounts = [_acct('a', 2000, DateTime(2026, 7, 2))];
      final lots = LotPacking.build(accounts, now,
          alreadyListed: LotPacking.listedThisCycle(june, now));
      expect(lots, isEmpty);
    });
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

  group('a list is a portal document, not a claim about the bag', () {
    // Auto-build once tried to reflect the field ledger: accounts whose cash he
    // was already carrying were promoted to the top of the first list. It made
    // the two systems disagree — a customer who paid ahead on the portal but
    // handed over cash this cycle was dropped from every list, so the money in
    // his bag had no paperwork behind it, and a customer who paid three months
    // at once was still listed for one. Lists are now built from the portal
    // book alone and edited by hand; the ledger stays his own field record.

    test('the packer takes accounts and a date — nothing else', () {
      // A compile-time contract as much as a runtime one: if a ledger argument
      // is ever threaded back in, this call stops compiling.
      final accounts = [_acct('a', 2000, DateTime(2026, 7, 2))];
      expect(LotPacking.build(accounts, now).single.items.single.accountNumber,
          'a');
    });

    test('ordering depends only on the portal next-due date', () {
      final accounts = [
        _acct('rich', 5000, DateTime(2026, 7, 2)), // worth more, due now
        _acct('small', 1000, DateTime(2026, 7, 2)),
      ];
      // No ledger can change this: within a tier, value decides.
      expect(LotPacking.build(accounts, now).first.items.first.accountNumber,
          'rich');
    });

    test('every packed account is listed at exactly one installment', () {
      // He adjusts the count by hand in the builder when someone pays ahead.
      final accounts = [
        _acct('a', 2000, DateTime(2026, 7, 2)),
        _acct('b', 3000, DateTime(2026, 6, 2)),
      ];
      final items = LotPacking.build(accounts, now).expand((l) => l.items);
      expect(items.map((i) => i.installments), everyElement(1));
    });
  });
}
