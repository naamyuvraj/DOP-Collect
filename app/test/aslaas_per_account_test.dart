import 'package:flutter_test/flutter_test.dart';

import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/models/lot.dart';
import 'package:dop_collect/models/rd_account.dart';
import 'package:dop_collect/screens/lists/lot_report.dart';

/// Regression: the ASLAAS number is held PER ACCOUNT on the portal
/// (`ASLAAS_NO_ARRAY[i]`), not once per agent. The app used to stamp one
/// settings value onto every row of a list, so every account in a list showed
/// the same number.
void main() {
  RdAccount acct(String n, {String? aslaas}) => RdAccount(
        accountNumber: n,
        customerName: 'CUST $n',
        denominationAmount: 1000,
        nextDueDate: DateTime(2026, 8, 1),
        monthsPaid: 10,
        aslaas: aslaas,
      );

  LotItem item(String n, {String? aslaas}) => LotItem(
        accountNumber: n,
        customerName: 'CUST $n',
        denomination: 1000,
        installments: 1,
        aslaas: aslaas,
      );

  test('each account keeps its own ASLAAS; a re-sync never wipes it', () async {
    final repo = MemoryAccountRepository();
    await repo.replaceAll([acct('A1'), acct('A2'), acct('A3')]);

    // Harvested off the portal's installment screen — one per account.
    final written = await repo
        .applyAslaas({'A1': '801357', 'A2': '801324', 'A3': '801335'});
    expect(written, 3);

    // A later list sync carries no ASLAAS at all: it must not blank them.
    await repo.replaceAll([acct('A1'), acct('A2'), acct('A3')]);

    expect((await repo.byAccountNumber('A1'))!.aslaas, '801357');
    expect((await repo.byAccountNumber('A2'))!.aslaas, '801324');
    expect((await repo.byAccountNumber('A3'))!.aslaas, '801335');
  });

  test('setAslaas writes one account only, and can clear it', () async {
    final repo = MemoryAccountRepository();
    await repo.replaceAll([acct('A1', aslaas: '111'), acct('A2')]);

    await repo.setAslaas('A2', '222');
    expect((await repo.byAccountNumber('A1'))!.aslaas, '111');
    expect((await repo.byAccountNumber('A2'))!.aslaas, '222');

    await repo.setAslaas('A2', '');
    expect((await repo.byAccountNumber('A2'))!.aslaas, isNull);
  });

  test('a list prints each row\'s own ASLAAS, not one shared number', () {
    final lot = Lot(
      createdAt: DateTime(2026, 8, 10),
      mode: 'Cash',
      items: [
        item('A1', aslaas: '801357'),
        item('A2', aslaas: '801324'),
        item('A3'), // never captured — falls back to the settings value
      ],
    );

    expect(aslaasOf(lot.items[0], '999'), '801357');
    expect(aslaasOf(lot.items[1], '999'), '801324');
    expect(aslaasOf(lot.items[2], '999'), '999');
    expect(aslaasOf(lot.items[2], ''), '');

    final text = lotReportText(lot, aslaas: '999');
    expect(text, contains('ASLAAS 801357'));
    expect(text, contains('ASLAAS 801324'));
    // The old bug: one number repeated on every line.
    expect('ASLAAS 801357'.allMatches(text).length, 1);
  });

  test('LotItem round-trips its ASLAAS through storage', () {
    final json = item('A1', aslaas: '801357').toJson();
    expect(LotItem.fromJson(json).aslaas, '801357');
    // Legacy rows (saved before the field existed) decode as "not set".
    expect(LotItem.fromJson({'a': 'A1', 'n': 'C', 'd': 1000, 'i': 1}).aslaas,
        isNull);
  });
}
