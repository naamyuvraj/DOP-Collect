import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/models/summaries.dart';
import 'package:flutter_test/flutter_test.dart';

/// The five-year / ten-year term boundary.
///
/// An RD runs 60 months and may be continued to 120. The portal never states
/// the term, so it is inferred from "Month Paid Upto" — and the inference used
/// `monthsPaid > 60`, which is wrong for exactly 60.
///
/// The case is not hypothetical. `recon/live/05_account_list__page_2.html` row
/// 6 is months paid 60 with "Next RD Installment Due Date" = 25-06-2026, and
/// rows 7 and 9 are months paid 60 with that cell BLANK. The blank ones have
/// finished; the dated one is being asked for its 61st installment and has
/// five more years to run. Only the due date separates them, and only a live
/// account reaches [RdAccount] at all — a finished one is a `MaturedRow`.
void main() {
  RdAccount account({required int monthsPaid, int denomination = 3200}) =>
      RdAccount(
        accountNumber: '020002767521',
        customerName: 'TEST',
        denominationAmount: denomination,
        // Live: the portal still names an installment, so this account has NOT
        // finished, whatever its months-paid count says.
        nextDueDate: DateTime(2026, 6, 25),
        monthsPaid: monthsPaid,
      );

  test('59 paid is a five-year account on its last installment', () {
    final a = account(monthsPaid: 59);
    expect(a.termMonths, 60);
    expect(a.installmentsToMaturity, 1);
  });

  test('exactly 60 paid AND still due is a continued ten-year account', () {
    // The regression. At `> 60` this read as term 60 / 0 left to run.
    final a = account(monthsPaid: 60);
    expect(a.termMonths, 120, reason: 'the 61st installment is due');
    expect(a.installmentsToMaturity, 60);
    expect(a.termYears, 10);
  });

  test('61 paid keeps behaving as it always did', () {
    final a = account(monthsPaid: 61);
    expect(a.termMonths, 120);
    expect(a.installmentsToMaturity, 59);
  });

  test('a continued account is not reported as about to mature', () {
    // The agent-visible symptom: a customer with five years still to run was
    // listed under Maturity, which is where he goes to see who to hand a
    // closure form to.
    final a = account(monthsPaid: 60);
    expect(AccountFilter.maturity.test(a, DateTime(2026, 9, 6)), isFalse);
    expect(AccountFilter.maturity.test(account(monthsPaid: 59), DateTime(2026, 9, 6)),
        isTrue);
  });

  test('the projected maturity value compounds the full continued term', () {
    // The money symptom. 20 quarters vs 40 is not a rounding difference: the
    // figure was a little over half of the real one.
    final continued = account(monthsPaid: 60);
    final lastYear = account(monthsPaid: 59);
    expect(continued.fullTermAmount, 3200 * 120);
    expect(continued.maturityAmount, greaterThan(lastYear.maturityAmount * 2));
  });
}
