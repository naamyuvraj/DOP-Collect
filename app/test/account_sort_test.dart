import 'package:flutter_test/flutter_test.dart';
import 'package:dop_collect/models/account_sort.dart';
import 'package:dop_collect/models/rd_account.dart';

RdAccount _a(String name, int denom, DateTime due) => RdAccount(
      accountNumber: name,
      customerName: name,
      denominationAmount: denom,
      nextDueDate: due,
      monthsPaid: 0,
    );

void main() {
  final low = _a('low', 500, DateTime(2026, 3, 10));
  final mid = _a('mid', 1000, DateTime(2026, 1, 5));
  final high = _a('high', 2000, DateTime(2026, 2, 20));
  final list = [low, mid, high];

  List<String> sorted(AccountSort s) =>
      ([...list]..sort(s.comparator)).map((a) => a.accountNumber).toList();

  test('amount high -> low', () {
    expect(sorted(AccountSort.amountDesc), ['high', 'mid', 'low']);
  });

  test('amount low -> high', () {
    expect(sorted(AccountSort.amountAsc), ['low', 'mid', 'high']);
  });

  test('due earliest first', () {
    expect(sorted(AccountSort.dueAsc), ['mid', 'high', 'low']);
  });

  test('due latest first', () {
    expect(sorted(AccountSort.dueDesc), ['low', 'high', 'mid']);
  });
}
