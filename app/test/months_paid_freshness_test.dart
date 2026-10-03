import 'dart:io';

import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/portal/agent_list_parser.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Month Paid Upto" going stale — the number the agent reads to answer
/// "how many installments has this customer actually paid?"
///
/// Two ways it froze, both of them silent.
void main() {
  RdAccount live(String n, {int monthsPaid = 58, int serial = 1}) => RdAccount(
        accountNumber: n,
        customerName: 'Sita Devi',
        denominationAmount: 1000,
        nextDueDate: DateTime(2026, 8, 25),
        monthsPaid: monthsPaid,
        serial: serial,
      );

  group('an account that matures keeps the portal\'s LAST figure', () {
    test('the maturity row refreshes months paid, even once closed', () async {
      final repo = MemoryAccountRepository();
      // Two syncs ago the portal said 58 installments.
      await repo.replaceAll([live('A1', monthsPaid: 58)]);

      // This sync it is gone from the account rows and appears as a maturity
      // at 60 — the last thing the portal will ever say about it. `replaceAll`
      // runs FIRST and closes it, which is exactly the order the real sync
      // uses, and is what used to make `recordMatured` skip the row entirely.
      await repo.replaceAll(const <RdAccount>[], complete: true);
      await repo.recordMatured([
        const MaturedRow(
          accountNumber: 'A1',
          customerName: 'Sita Devi',
          denominationAmount: 1000,
          monthsPaid: 60,
        )
      ]);

      // Matured Accounts reads `maturedSince`; `all()` is live accounts only.
      final a = (await repo.maturedSince(DateTime(2000)))
          .firstWhere((x) => x.accountNumber == 'A1');
      expect(a.monthsPaid, 60,
          reason: 'Matured Accounts must not show a figure two syncs old');
      expect(a.isClosed, isTrue);
    });

    test('a later sync refreshes the figure but never moves the closure date',
        () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([live('A1', monthsPaid: 58)]);
      final closedOn = DateTime(2026, 7, 1);
      await repo.recordMatured([
        const MaturedRow(
            accountNumber: 'A1',
            customerName: 'Sita Devi',
            denominationAmount: 1000,
            monthsPaid: 59)
      ], asOf: closedOn);

      // Next month's sync still lists it as matured, now with the final 60.
      await repo.recordMatured([
        const MaturedRow(
            accountNumber: 'A1',
            customerName: 'Sita Devi',
            denominationAmount: 1000,
            monthsPaid: 60)
      ], asOf: DateTime(2026, 8, 1));

      final a = (await repo.maturedSince(DateTime(2000)))
          .firstWhere((x) => x.accountNumber == 'A1');
      expect(a.monthsPaid, 60);
      expect(a.closedAt, closedOn,
          reason: 'moving it would push the account back to the top of the '
              'Matured list every single month');
    });
  });

  test('no opening date is invented when an account closes', () {
    // `nextDue - monthsPaid` gives the right month and a day the app never
    // knew: the portal normalises installment due dates, so the day it holds
    // is not the day the account was opened. Writing that into `opening_date`
    // — which everywhere else means "the portal said so" — would print a
    // confident wrong date on the Account screen. It stays null; the screen
    // says "Not available" until Deep Sync fetches the real one.
    final src = File('lib/data/account_repository.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(src.contains('derivedOpeningDate'), isFalse,
        reason: 'the store must never derive an opening date');
  });

  test('a matured account still has no opening date of its own', () async {
    final repo = MemoryAccountRepository();
    await repo.replaceAll([live('A1', monthsPaid: 58)]);
    await repo.replaceAll(const <RdAccount>[], complete: true);
    await repo.recordMatured([
      const MaturedRow(
          accountNumber: 'A1',
          customerName: 'Sita Devi',
          denominationAmount: 1000,
          monthsPaid: 60)
    ]);

    final a = (await repo.maturedSince(DateTime(2000)))
        .firstWhere((x) => x.accountNumber == 'A1');
    expect(a.openingDate, isNull,
        reason: 'the Account screen shows "Not available", not a guess');
    expect(a.monthsPaid, 60, reason: 'this part still holds');
  });

  group('one unreadable cell must not close a live customer', () {
    test('a rejected row counts as SEEN by a complete sync', () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([live('A1'), live('A2', serial: 2)]);

      // A2's denomination would not parse this month, so it never became an
      // RdAccount. It is still a real customer the portal listed.
      final merge = await repo.replaceAll([live('A1')],
          complete: true, alsoSeen: {'A2'});

      expect(merge.closed, isEmpty);
      final a2 = (await repo.all()).firstWhere((x) => x.accountNumber == 'A2');
      expect(a2.isClosed, isFalse,
          reason: 'he is on the round tomorrow, whatever one cell said');
    });

    test('without that, absence still closes — the rule is unchanged', () async {
      final repo = MemoryAccountRepository();
      await repo.replaceAll([live('A1'), live('A2', serial: 2)]);
      final merge = await repo.replaceAll([live('A1')], complete: true);
      expect(merge.closed.map((a) => a.accountNumber), ['A2']);
    });

    test('the parser names the rows it dropped', () {
      const html = '''
      <table>
        <tr><th>Account No</th><th>Account Name</th><th>Denomination</th>
            <th>Month Paid Upto</th><th>Next RD Installment Due Date</th></tr>
        <tr><td>020000000001</td><td>A</td><td>1,000.00 Cr.</td><td>58</td>
            <td>25-09-2026</td></tr>
        <tr><td>020000000002</td><td>B</td><td>-</td><td>58</td>
            <td>25-09-2026</td></tr>
        <tr><td>020000000003</td><td>C</td><td>1,000.00 Cr.</td><td>58</td>
            <td>rubbish</td></tr>
      </table>''';
      final parsed = AgentListParser.parse(html);

      expect(parsed.accounts.map((a) => a.accountNumber), ['020000000001']);
      expect(parsed.rejected, 2);
      expect(parsed.rejectedAccounts, {'020000000002', '020000000003'},
          reason: 'the merge cannot spare them without knowing who they are');
    });
  });
}
