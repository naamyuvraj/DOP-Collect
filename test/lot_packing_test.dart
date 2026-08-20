import 'package:dop_collect/models/lot.dart';
import 'package:dop_collect/models/lot_packing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Auto-build is gone — lists are assembled by hand in the list builder — so
/// the packing tests that lived here went with it.
///
/// What survives is the rule the collect sheet still leans on: a saved list
/// lays claim to its accounts, so a customer whose money is already on a list
/// shows as settled rather than as still owing. The claim has to expire, or
/// he disappears from next month's round too.
void main() {
  final now = DateTime(2026, 7, 15);

  /// `submitted` is not decoration: an unsubmitted list blocks its accounts for
  /// ever, and only a FILED one expires with its cycle. See
  /// LotPacking._stillBlocks.
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

  group('the listed-this-cycle claim expires with the cycle', () {
    test('a list built this month holds its accounts', () {
      expect(
          LotPacking.listedThisCycle([lotOn(DateTime(2026, 7, 3), 'a')], now),
          {'a'});
    });

    test("last month's SUBMITTED list does not hold them into this month", () {
      // The regression that mattered: the old `status == deposited` flag was
      // never reset, so every customer collected in June stayed marked in July,
      // August and forever after. Derived from the lists, June's list stops
      // counting once July starts — but only because the cash was actually
      // handed in, which is what `submitted` says here.
      final june = [lotOn(DateTime(2026, 6, 3), 'a', submitted: true)];
      expect(LotPacking.listedThisCycle(june, now), isEmpty);
    });

    test('an UNSUBMITTED list from last month still holds them', () {
      // Nothing has been handed in, so that list is still a live claim on the
      // account however old it is — collecting from the customer again would
      // be taking the same month's money twice.
      final june = [lotOn(DateTime(2026, 6, 3), 'a')];
      expect(LotPacking.listedThisCycle(june, now), {'a'});
    });

    test('a list SUBMITTED this month holds them for this month', () {
      final filed = [lotOn(DateTime(2026, 7, 3), 'a', submitted: true)];
      expect(LotPacking.listedThisCycle(filed, now), {'a'});
    });
  });
}
