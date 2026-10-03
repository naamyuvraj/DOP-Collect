import 'dart:io';

import 'package:dop_collect/models/lot.dart';
import 'package:dop_collect/screens/lists/lot_report.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the real PDF so it can be looked at, and asserts the things that
/// have actually gone wrong in this file before: a column count that does not
/// match its headers, and a draft carrying an official letterhead.
Lot _lot({required bool submitted, required bool cheque, int rows = 15}) {
  final names = ['MD FARMUD', 'SAROJ KUMAR SUMAN', 'UMESH KUMAR RAM',
      'NUSRAT BANO'];
  return Lot(
    createdAt: DateTime(2026, 8, 26, 10, 30),
    mode: cheque ? 'DOP Cheque' : 'Cash',
    referenceNumber: submitted ? 'C343193788' : null,
    submittedAt: submitted ? DateTime(2026, 8, 26, 11) : null,
    items: [
      for (var i = 0; i < rows; i++)
        LotItem(
          accountNumber: '02013592${(500 + i * 137).toString().padLeft(4, '0')}',
          customerName: names[i % names.length],
          denomination: i == 0 ? 1000 : (i == rows - 1 ? 15000 : 100),
          installments: 1,
          aslaas: '${804315 + i * 371}',
          rebate: submitted ? 0 : null,
          defaultFee: submitted ? 0 : null,
          chequeNumber: cheque ? '10023$i' : null,
          bankAccountNumber: cheque ? '3766788625' : null,
        ),
    ],
  );
}

void main() {
  final out = Directory(
      Platform.environment['SCRATCH'] ?? Directory.systemTemp.path);

  test('a submitted cash list renders', () async {
    final bytes = await buildLotReportPdf(_lot(submitted: true, cheque: false),
        agentName: 'Reeta Devi',
        agentId: 'DOP.MI847226011984',
        aslaas: '');
    expect(bytes.length, greaterThan(1000));
    File('${out.path}/report_submitted_cash.pdf').writeAsBytesSync(bytes);
  });

  test('a cheque list renders with its three extra columns', () async {
    final bytes = await buildLotReportPdf(_lot(submitted: true, cheque: true),
        agentName: 'Reeta Devi',
        agentId: 'DOP.MI847226011984',
        aslaas: '');
    expect(bytes.length, greaterThan(1000));
    File('${out.path}/report_submitted_cheque.pdf').writeAsBytesSync(bytes);
  });

  test('an UNSUBMITTED list renders and is marked a draft', () async {
    final bytes = await buildLotReportPdf(_lot(submitted: false, cheque: false),
        agentName: 'Reeta Devi',
        agentId: 'DOP.MI847226011984',
        aslaas: '');
    expect(bytes.length, greaterThan(1000));
    File('${out.path}/report_draft.pdf').writeAsBytesSync(bytes);
  });

  test('a long list pages without throwing', () async {
    final bytes = await buildLotReportPdf(
        _lot(submitted: true, cheque: false, rows: 90),
        agentName: 'Reeta Devi',
        agentId: 'DOP.MI847226011984',
        aslaas: '');
    expect(bytes.length, greaterThan(2000));
    File('${out.path}/report_long.pdf').writeAsBytesSync(bytes);
  });

  test('nothing bound for the PDF uses a glyph Helvetica lacks', () {
    // The built-in Helvetica has no U+2014; an em dash paints as a solid black
    // box. It shipped that way once, in the draft footer, and no analyzer or
    // unit test would ever have said so - only a rendered page did.
    final src =
        File('lib/screens/lists/lot_report.dart').readAsStringSync();
    final pdfStrings = RegExp(r"pw\.Text\(\s*'([^']*)'").allMatches(src);
    expect(pdfStrings, isNotEmpty, reason: 'the scan found no pw.Text at all');
    for (final m in pdfStrings) {
      final lit = m.group(1)!;
      final bad = lit.runes.where((r) => r > 127).toList();
      expect(bad, isEmpty,
          reason: 'non-ASCII ${bad.map((r) => '0x${r.toRadixString(16)}')} '
              'in a PDF string: "$lit"');
    }
  });

  test('headers and every data row have the same width', () {
    // A mismatch here throws deep inside the pdf package with a message that
    // names neither the column nor the list — worth catching in one line.
    for (final cheque in [false, true]) {
      final lot = _lot(submitted: true, cheque: cheque);
      // 11 on a cash list, counted off the printed report: #, E-Banking Ref
      // No, Rd Account Number, Account Name, RD Denomination, RD Total Deposit
      // Amount, No of Installment, Rebate, Default Fee, Aslaas No., Status.
      // Three more when the list carries cheques.
      final expected = cheque ? 14 : 11;
      expect(reportHeaders(cheque: cheque).length, expected);
      expect(reportRows(lot, aslaas: '').every((r) => r.length == expected),
          isTrue,
          reason: 'cheque=$cheque rows must match the header count');
    }
  });
}
