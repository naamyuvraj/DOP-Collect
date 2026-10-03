import 'package:dop_collect/models/collection.dart';
import 'package:dop_collect/util/receipt.dart';
import 'package:flutter_test/flutter_test.dart';

Collection _c(String acct, int amount, DateTime at) => Collection(
      accountNumber: acct,
      amount: amount,
      collectedAt: at,
      cycleYm: Collection.cycleOf(at),
    );

void main() {
  final at = DateTime(2026, 8, 12, 14, 34);

  group('customer receipt', () {
    test('names the amount, the account and the balance still owed', () {
      final t = Receipt.collection(
        customerName: 'RAMESH KUMAR',
        accountNumber: '020145044718',
        amount: 30,
        at: at,
        collectedThisCycle: 640,
        monthlyAmount: 1000,
        agentName: 'Yuvraj',
      );
      expect(t, contains('Received ₹30'));
      expect(t, contains('RAMESH KUMAR'));
      expect(t, contains('020145044718'));
      expect(t, contains('12-Aug-2026'));
      expect(t, contains('₹640 of ₹1,000'));
      expect(t, contains('Still to pay: ₹360'));
      expect(t, contains('— Yuvraj'));
    });

    test('says the month is fully paid once it is', () {
      final t = Receipt.collection(
        customerName: 'SUNITA',
        accountNumber: '02001',
        amount: 360,
        at: at,
        collectedThisCycle: 1000,
        monthlyAmount: 1000,
      );
      expect(t, contains('Fully paid for this month'));
      expect(t, isNot(contains('Still to pay')));
    });

    test('never claims the money is deposited at the post office', () {
      // The receipt covers cash handed to the agent. Saying anything stronger
      // is what turns a delayed deposit into a dispute.
      final t = Receipt.collection(
        customerName: 'A',
        accountNumber: '1',
        amount: 100,
        at: at,
        collectedThisCycle: 100,
        monthlyAmount: 1000,
      );
      expect(t, contains('Received by your agent'));
      expect(t, contains('deposit is made at the post office at month end'));
    });

    test('an unknown agent name leaves no dangling signature', () {
      final t = Receipt.collection(
        customerName: 'A',
        accountNumber: '1',
        amount: 100,
        at: at,
        collectedThisCycle: 100,
        monthlyAmount: 1000,
        agentName: '   ',
      );
      expect(t, isNot(contains('—')));
    });
  });

  group('day summary', () {
    final entries = [
      _c('1', 1000, DateTime(2026, 8, 12, 9, 10)),
      _c('2', 30, DateTime(2026, 8, 12, 11, 5)),
    ];
    final names = {'1': 'RAMESH', '2': 'SUNITA'};

    test('totals the day and lists it in the order he walked it', () {
      final t = Receipt.daySummary(
          day: at, entries: entries, namesByAccount: names);
      expect(t, contains('2 collections · ₹1,030'));
      expect(t.indexOf('RAMESH'), lessThan(t.indexOf('SUNITA')));
    });

    test('states a shortfall when the counted cash is less', () {
      final t = Receipt.daySummary(
          day: at, entries: entries, namesByAccount: names, counted: 830);
      expect(t, contains('Cash counted: ₹830'));
      expect(t, contains('Short by ₹200'));
    });

    test('states extra cash when the count is higher', () {
      final t = Receipt.daySummary(
          day: at, entries: entries, namesByAccount: names, counted: 1130);
      expect(t, contains('Extra ₹100'));
    });

    test('says it tallies when the count matches', () {
      final t = Receipt.daySummary(
          day: at, entries: entries, namesByAccount: names, counted: 1030);
      expect(t, contains('Tallies'));
      expect(t, isNot(contains('Short')));
    });

    test('falls back to the account number when the name is unknown', () {
      final t = Receipt.daySummary(
          day: at, entries: entries, namesByAccount: const {});
      expect(t, contains('1'));
      expect(t, contains('2'));
    });
  });

}
