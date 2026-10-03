import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/models/summaries.dart';
import 'package:flutter_test/flutter_test.dart';

/// An account opened on [opened]. `openingDate` is set directly so the test is
/// about the WINDOW and not about how an opening date gets derived.
RdAccount _opened(String n, DateTime opened) => RdAccount(
      accountNumber: n,
      customerName: 'C$n',
      denominationAmount: 2000,
      nextDueDate: DateTime(2026, 8, 5),
      monthsPaid: 1,
      openingDate: opened,
    );

void main() {
  // Mid-month deliberately: the old window was anchored on today's DATE, so it
  // split both July and August in half and every one of these cases turned on
  // which day you happened to look.
  final now = DateTime(2026, 8, 19);

  final thisMonthEarly = _opened('a', DateTime(2026, 8, 3));
  final thisMonthLate = _opened('b', DateTime(2026, 8, 19));
  final lastMonthEarly = _opened('c', DateTime(2026, 7, 3));
  final lastMonthLate = _opened('d', DateTime(2026, 7, 28));
  final twoBack = _opened('e', DateTime(2026, 6, 15));
  final threeBack = _opened('f', DateTime(2026, 5, 15));

  final all = [
    thisMonthEarly, thisMonthLate, lastMonthEarly,
    lastMonthLate, twoBack, threeBack,
  ];

  List<String> shown(int months) {
    AccountFilter.newAccountMonths = months;
    return AccountFilter.newAccounts
        .filter(all, now)
        .map((a) => a.accountNumber)
        .toList();
  }

  tearDown(() => AccountFilter.newAccountMonths = 1);

  group('the New Accounts window is calendar months, not a rolling one', () {
    test('1 month = this month only, whole month', () {
      // The 3rd of THIS month is in; the 3rd of LAST month is not. Under the
      // old day-anchored window the 3rd of August was in and the 3rd of July
      // was out only by luck of the date — on the 2nd, both flipped.
      expect(shown(1), ['a', 'b']);
    });

    test('2 months = this month and last, in full', () {
      // The 3rd of July is the case that matters: it is more than one calendar
      // month before the 19th, so a rolling window dropped it.
      expect(shown(2), ['a', 'b', 'c', 'd']);
    });

    test('3 months = this month and the two before it', () {
      expect(shown(3), ['a', 'b', 'c', 'd', 'e']);
      expect(shown(3), isNot(contains('f')));
    });

    test('an account opened on the 1st of the month is included', () {
      // Boundary: the window starts at midnight on the 1st, so the 1st itself
      // must be in, not one day out.
      AccountFilter.newAccountMonths = 1;
      final first = _opened('g', DateTime(2026, 8, 1));
      expect(AccountFilter.newAccounts.filter([first], now), hasLength(1));
    });

    test('the window does not move when the day does', () {
      AccountFilter.newAccountMonths = 1;
      final on1st = AccountFilter.newAccountsFrom(DateTime(2026, 8, 1));
      final on28th = AccountFilter.newAccountsFrom(DateTime(2026, 8, 28));
      expect(on1st, on28th, reason: 'a month is a month, whatever day it is');
    });

    test('crossing a year boundary walks back into the previous year', () {
      AccountFilter.newAccountMonths = 3;
      expect(AccountFilter.newAccountsFrom(DateTime(2026, 1, 15)),
          DateTime(2025, 11, 1));
    });
  });

  group('the window says which months it covers', () {
    test('one month names it', () {
      AccountFilter.newAccountMonths = 1;
      expect(AccountFilter.newAccountsWindowLabel(now), 'August 2026');
    });

    test('several months read as a range, with the year said once', () {
      AccountFilter.newAccountMonths = 3;
      expect(AccountFilter.newAccountsWindowLabel(now), 'June - August 2026');
    });

    test('a range across new year keeps both years', () {
      AccountFilter.newAccountMonths = 3;
      expect(AccountFilter.newAccountsWindowLabel(DateTime(2026, 1, 15)),
          'November 2025 - January 2026');
    });
  });
}
