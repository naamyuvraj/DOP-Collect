import 'package:flutter_test/flutter_test.dart';

import 'package:dop_collect/models/lot.dart';
import 'package:dop_collect/models/lot_packing.dart';
import 'package:dop_collect/models/rd_account.dart';

/// Foundation for the portal submission work: the order the list builder
/// offers by default, and Lot/LotItem persistence of the cheque + reference
/// fields.
///
/// The two limit tests that were here drove `LotPacking.pack`, which went with
/// auto-build. The limits themselves are still enforced — by the list builder,
/// against its own `ListBuilderScreen.lotCap` / `maxAccounts`.
void main() {
  final now = DateTime(2026, 7, 30);

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
