import 'package:flutter_test/flutter_test.dart';

import 'package:dop_collect/models/lot.dart';
import 'package:dop_collect/models/lot_packing.dart';
import 'package:dop_collect/models/rd_account.dart';

/// Foundation for the portal submission work: the two packing limits
/// (50 accounts/list, ₹20k cash-only) and Lot/LotItem persistence of the new
/// cheque + reference fields.
void main() {
  final now = DateTime(2026, 7, 30);

  RdAccount acct(String n, int denom) => RdAccount(
        accountNumber: n,
        customerName: 'C$n',
        denominationAmount: denom,
        nextDueDate: now,
        monthsPaid: 10,
      );

  group('priority order (most valuable + reliable first)', () {
    RdAccount at(String n, int denom, DateTime due) => RdAccount(
        accountNumber: n,
        customerName: 'C$n',
        denominationAmount: denom,
        nextDueDate: due,
        monthsPaid: 10);
    test('on-time-owing > overdue > paid-ahead, then by value', () {
      final base = DateTime(2026, 7, 15);
      final list = [
        at('ahead3k', 3000, DateTime(2026, 9, 15)), // paid ahead — must be last
        at('overdue15k', 15000, DateTime(2026, 5, 10)), // overdue, high value
        at('ontime6k', 6000, DateTime(2026, 7, 20)), // due this month — first
        at('ahead6k', 6000, DateTime(2026, 9, 15)), // paid ahead
      ]..sort((a, b) => LotPacking.priorityCompare(a, b, base));
      // On-time owers first, then overdue, then paid-ahead (by value within).
      expect(list.map((a) => a.accountNumber).toList(),
          ['ontime6k', 'overdue15k', 'ahead6k', 'ahead3k']);
    });
  });

  group('LotPacking limits', () {
    test('cash caps the rupee total at ₹20,000', () {
      // 5 × ₹6,000 = ₹30,000. Cash → 3 per lot (₹18k), then 2.
      final lots = LotPacking.pack(
        [for (var i = 0; i < 5; i++) acct('$i', 6000)],
        now,
      );
      expect(lots.length, 2);
      expect(lots[0].totalAmount, lessThanOrEqualTo(20000));
      expect(lots.every((l) => l.totalAmount <= 20000), true);
    });

    test('cheque modes have NO amount cap, only the 50-account cap', () {
      // 60 × ₹1,000 = ₹60,000 in DOP Cheque mode → split by count (50 + 10),
      // NOT by ₹20,000.
      final lots = LotPacking.pack(
        [for (var i = 0; i < 60; i++) acct('$i', 1000)],
        now,
        mode: 'DOP Cheque',
      );
      expect(lots.length, 2);
      expect(lots[0].count, 50);
      expect(lots[1].count, 10);
      expect(lots[0].totalAmount, 50000); // well over ₹20k — allowed for cheque
    });

    test('cash also honours the 50-account cap when amounts are tiny', () {
      // 55 × ₹100 = ₹5,500 (never hits ₹20k) → still splits at 50.
      final lots = LotPacking.pack(
        [for (var i = 0; i < 55; i++) acct('$i', 100)],
        now,
      );
      expect(lots.length, 2);
      expect(lots[0].count, 50);
      expect(lots[1].count, 5);
    });
  });

  group('Lot / LotItem persistence', () {
    test('cheque fields + reference + submittedAt round-trip through toMap', () {
      final lot = Lot(
        id: 7,
        createdAt: now,
        mode: 'DOP Cheque',
        referenceNumber: 'DC123456789',
        submittedAt: DateTime(2026, 7, 30, 11, 5),
        items: const [
          LotItem(
            accountNumber: '020000000001',
            customerName: 'RAMESH',
            denomination: 5000,
            installments: 2,
            chequeNumber: '556677',
            bankAccountNumber: '9988776655',
          ),
        ],
      );
      final back = Lot.fromMap(lot.toMap());
      expect(back.referenceNumber, 'DC123456789');
      expect(back.submittedAt, DateTime(2026, 7, 30, 11, 5));
      expect(back.isSubmitted, true);
      expect(back.items.first.chequeNumber, '556677');
      expect(back.items.first.bankAccountNumber, '9988776655');
    });

    test('backward-compatible: old rows without the new fields load as null', () {
      // An existing (pre-v5) row: no reference/submit columns, cash item JSON
      // without cheque keys.
      final old = <String, Object?>{
        'id': 3,
        'created_at': now.toIso8601String(),
        'mode': 'Cash',
        'items_json': '[{"a":"020000000002","n":"SITA","d":3000,"i":1}]',
      };
      final lot = Lot.fromMap(old);
      expect(lot.referenceNumber, isNull);
      expect(lot.submittedAt, isNull);
      expect(lot.isSubmitted, false);
      expect(lot.items.first.chequeNumber, isNull);
      expect(lot.items.first.bankAccountNumber, isNull);
    });
  });
}
