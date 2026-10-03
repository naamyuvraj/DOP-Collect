import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';

/// An account's maturity must be projected with the rate locked at ITS opening
/// date, not a flat current rate.
void main() {
  RdAccount account({required DateTime nextDue, required int monthsPaid}) =>
      RdAccount(
        accountNumber: '020002767521',
        customerName: 'TEST',
        denominationAmount: 2000,
        nextDueDate: nextDue,
        monthsPaid: monthsPaid,
      );

  test('rate follows the derived opening date', () {
    // nextDue - monthsPaid = opening. 94 months before Sep-2026 => Nov-2018.
    final a = account(nextDue: DateTime(2026, 9, 2), monthsPaid: 94);
    expect(a.effectiveOpeningDate.year, 2018);
    expect(a.effectiveOpeningDate.month, 11);
    expect(a.annualRate, 7.3); // rate in Nov 2018
  });

  test('a covid-era account gets the lower locked rate', () {
    // Opened mid-2020 (5.8% era): nextDue Jul-2025, 60 paid => Jul-2020.
    final a = account(nextDue: DateTime(2025, 7, 10), monthsPaid: 60);
    expect(a.effectiveOpeningDate.year, 2020);
    expect(a.annualRate, 5.8);
  });

  test('lower opening rate yields a lower maturity for the same deposits', () {
    final high = account(nextDue: DateTime(2023, 12, 1), monthsPaid: 60); // 2018
    final low = account(nextDue: DateTime(2025, 7, 1), monthsPaid: 60); // 2020
    expect(high.annualRate, greaterThan(low.annualRate));
    expect(high.maturityAmount, greaterThan(low.maturityAmount));
  });
}
