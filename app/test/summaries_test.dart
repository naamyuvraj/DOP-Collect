import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/models/summaries.dart';
import 'package:flutter_test/flutter_test.dart';

RdAccount acc(String due, {int denom = 5000, int paid = 30}) => RdAccount(
      accountNumber: '02000000000$due'.replaceAll('-', ''),
      customerName: 'X',
      denominationAmount: denom,
      nextDueDate: DateTime.parse(due),
      monthsPaid: paid,
    );

void main() {
  // "Now" fixed mid-second-fortnight of July 2026 (like the real run).
  final now = DateTime(2026, 7, 22);

  test('Pending/Deposited/Defaulter derive from next due date vs current month',
      () {
    final accounts = [
      acc('2026-07-08'), // day 8 first half, due THIS month  -> 1st Pending
      acc('2026-07-20'), // day 20 second half, due THIS month -> 2nd Pending
      acc('2026-08-08'), // future month, day 8  -> 1st Deposited
      acc('2026-09-20'), // future month, day 20 -> 2nd Deposited
      acc('2026-05-10'), // 2 months overdue -> Defaulter
    ];

    int c(AccountFilter f) => f.statOf(accounts, now).count;

    expect(c(AccountFilter.firstHalfPending), 1);
    expect(c(AccountFilter.secondHalfPending), 1);
    expect(c(AccountFilter.firstHalfDeposited), 1);
    expect(c(AccountFilter.secondHalfDeposited), 1);
    expect(c(AccountFilter.defaulters), 1);

    // Every non-defaulter lands in exactly one half bucket -> 4; +1 defaulter = 5.
    final bucketed = c(AccountFilter.firstHalfPending) +
        c(AccountFilter.secondHalfPending) +
        c(AccountFilter.firstHalfDeposited) +
        c(AccountFilter.secondHalfDeposited) +
        c(AccountFilter.defaulters);
    expect(bucketed, accounts.length);
  });

  test('defaulter amount is arrears (denomination x months behind)', () {
    final a = [acc('2026-05-10', denom: 2000)]; // 2 months behind
    final s = AccountFilter.defaulters.statOf(a, now);
    expect(s.count, 1);
    expect(s.amount, 2000 * 2);
  });
}
