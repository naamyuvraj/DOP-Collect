import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/lot.dart';
import '../../util/format.dart';

/// A LOCAL list number derived from the lot's creation time — an agent-side
/// identifier only. The official E-Banking reference is assigned by the DOP
/// portal on submission; this app never submits, so this is never that number.
String lotReference(Lot lot) =>
    'L${(lot.createdAt.millisecondsSinceEpoch % 1000000000).toString().padLeft(9, '0')}';

/// This row's ASLAAS number: the ACCOUNT's own (each account has a different
/// one on the portal). [fallback] is the legacy agency-wide settings value, used
/// only for lists saved before ASLAAS became per-account, and '' when unknown.
String aslaasOf(LotItem it, String fallback) {
  final own = it.aslaas?.trim() ?? '';
  return own.isNotEmpty ? own : fallback.trim();
}

/// Plain-text summary for WhatsApp / share-as-text. Honestly a DRAFT the agent
/// prepared on the phone — not an official DOP submission receipt.
String lotReportText(Lot lot, {String aslaas = ''}) {
  final submitted = lot.referenceNumber != null;
  final ref = lot.referenceNumber ?? lotReference(lot);
  final b = StringBuffer()
    ..writeln(submitted
        ? 'RD Installment Report (submitted)'
        : 'RD Installment List (DRAFT — prepared in DOP Collect)')
    ..writeln(submitted
        ? 'E-Banking Ref: $ref'
        : 'Not an official receipt. Submit on the DOP portal for the '
            'E-Banking reference.')
    ..writeln(submitted ? '' : 'List No (local): $ref')
    ..writeln('Date: ${DateFormat('dd-MMM-yyyy').format(lot.createdAt)}')
    ..writeln('Accounts: ${lot.count}  Total: ${inr(lot.totalAmount)}')
    ..writeln('');
  // ASLAAS is per line, not per list — each account has its own number.
  for (var i = 0; i < lot.items.length; i++) {
    final it = lot.items[i];
    final asl = aslaasOf(it, aslaas);
    b.writeln('${i + 1}. ${it.customerName}  ${it.accountNumber}  '
        'x${it.installments}  ${inr(it.amount)}  '
        'ASLAAS ${asl.isEmpty ? '-' : asl}');
  }
  return b.toString();
}

/// Finacle-style amounts: "2,000.00 Cr." (Indian grouping, 2 decimals).
String _cr(num v) => '${NumberFormat('#,##,##0.00').format(v)} Cr.';
String _amt(num v) => NumberFormat('#,##,##0.00').format(v);

/// One list's report as a page. A SUBMITTED list (real portal reference) is
/// rendered in the portal's own "Recurring Deposit Installment Report" layout,
/// with the agent's real data — a faithful copy of their own transaction.
/// A not-yet-submitted list is a clearly-marked DRAFT working copy.
pw.MultiPage _lotPage(
  Lot lot, {
  required String agentName,
  required String agentId,
  required String aslaas,
}) =>
    lot.referenceNumber != null
        ? _officialPage(lot, agentId: agentId, aslaas: aslaas)
        : _draftPage(lot, agentName: agentName, agentId: agentId, aslaas: aslaas);

/// Matches the DOP portal's Reports PDF for a submitted list.
pw.MultiPage _officialPage(Lot lot,
    {required String agentId, required String aslaas}) {
  final ref = lot.referenceNumber!;
  final when = lot.submittedAt ?? lot.createdAt;
  final dmy = DateFormat('dd-MM-yyyy').format(when);
  final stamp = DateFormat('dd-MM-yyyy hh:mm:ss a').format(when);
  // The portal prints the raw agent id (e.g. "MI8472350100005"), not the
  // "DOP." login prefix the app stores it under.
  final cleanAgent =
      agentId.replaceFirst(RegExp(r'^DOP[.\s]*', caseSensitive: false), '');

  const headers = <String>[
    'E-Banking\nRef No',
    'RD Account\nNumber',
    'Account\nName',
    'RD\nDenomination',
    'RD Total\nDeposit Amount',
    'No of\nInstallments',
    'Rebate',
    'Default\nfee',
    'Bank Name',
    'Cheque\nNumber',
    'SB Account\nNo',
    'ASLAAS\nNumber',
    'Status',
    'Last Created\nDate & Time',
  ];
  final data = [
    for (final it in lot.items)
      [
        ref,
        it.accountNumber,
        it.customerName,
        _cr(it.denomination),
        _cr(it.amount),
        '${it.installments}',
        '0.00',
        '0.00',
        '', // Bank Name (not captured by the app)
        it.chequeNumber ?? '',
        it.bankAccountNumber ?? '',
        aslaasOf(it, aslaas),
        'Success',
        stamp,
      ],
  ];

  pw.Widget crit(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        child: pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          pw.SizedBox(
              width: 150,
              child: pw.Text('$label ',
                  textAlign: pw.TextAlign.right,
                  style: const pw.TextStyle(fontSize: 8.5))),
          pw.SizedBox(width: 4),
          pw.Text(value, style: const pw.TextStyle(fontSize: 8.5)),
        ]),
      );

  const red = PdfColor.fromInt(0xFFC1272D); // India Post red
  const grey = PdfColor.fromInt(0xFFE3E3E3); // header band
  const zebra = PdfColor.fromInt(0xFFF2F2F2); // alternate row shading
  return pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(22),
    build: (ctx) => [
      // Government letterhead — all red, no rule line, matching the portal PDF.
      // (The India Post emblem is intentionally not reproduced.)
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('Govt. of India',
            style: const pw.TextStyle(
                fontSize: 13, fontWeight: pw.FontWeight.bold, color: red)),
        pw.SizedBox(height: 1),
        pw.Text('Ministry of Communications',
            style: const pw.TextStyle(fontSize: 10, color: red)),
        pw.SizedBox(height: 1),
        pw.Text('Department of Posts',
            style: const pw.TextStyle(
                fontSize: 15, fontWeight: pw.FontWeight.bold, color: red)),
      ]),
      pw.SizedBox(height: 34),
      pw.Center(
        child: pw.Text('RECURRING DEPOSIT INSTALLMENT REPORT',
            style: const pw.TextStyle(fontSize: 11)),
      ),
      pw.SizedBox(height: 18),
      pw.Text('Search Criteria', style: const pw.TextStyle(fontSize: 8)),
      pw.SizedBox(height: 8),
      pw.Center(
        child: pw.Column(children: [
          crit('Agent Id:', cleanAgent.isEmpty ? '-' : cleanAgent),
          crit('From Date:', '$dmy   To Date: $dmy'),
          crit('List Reference No:', ref),
          crit('Status:', 'Success'),
          crit('Cheque No.:', ''),
          crit('Type Of Report:', 'SR'),
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.Text('Search Results', style: const pw.TextStyle(fontSize: 8)),
      pw.SizedBox(height: 8),
      // Left blank exactly as the portal's report does — the total appears in
      // the footer summary below.
      pw.Center(
        child: pw.Column(children: [
          crit('Total Amount:', ''),
          crit('Total No Of Records:', ''),
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: data,
        border: null, // no gridlines — grey header + zebra rows only
        headerStyle:
            const pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 6),
        headerDecoration: const pw.BoxDecoration(color: grey),
        oddRowDecoration: const pw.BoxDecoration(color: zebra),
        cellAlignment: pw.Alignment.centerLeft,
        headerAlignment: pw.Alignment.centerLeft,
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 5),
      ),
      pw.SizedBox(height: 16),
      pw.TableHelper.fromTextArray(
        headers: const ['E-Banking Ref No', 'Total Deposit Amount'],
        data: [
          [ref, _amt(lot.totalAmount)]
        ],
        border: null,
        headerStyle:
            const pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 8),
        headerDecoration: const pw.BoxDecoration(color: grey),
        cellAlignment: pw.Alignment.centerLeft,
        headerAlignment: pw.Alignment.centerLeft,
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
    ],
  );
}

/// A not-yet-submitted list — clearly a DRAFT working copy, never an official
/// receipt (no Govt-of-India header, no "Success").
pw.MultiPage _draftPage(Lot lot,
    {required String agentName,
    required String agentId,
    required String aslaas}) {
  final ref = lotReference(lot);
  final date = DateFormat('dd-MMM-yyyy').format(lot.createdAt);
  const headers = <String>[
    'Sr\nno',
    'List No.\n(local)',
    'Rd Account\nNumber',
    'Account\nName',
    'RD\nDenomination',
    'RD Total\nDeposit Amount',
    'No of\nInstallment',
    // Per account — this is the sheet he keys from, so each row carries its own.
    'ASLAAS\nNumber',
    'Status',
  ];
  final data = [
    for (var i = 0; i < lot.items.length; i++)
      [
        '${i + 1}',
        ref,
        lot.items[i].accountNumber,
        lot.items[i].customerName,
        _cr(lot.items[i].denomination),
        _cr(lot.items[i].amount),
        '${lot.items[i].installments}',
        aslaasOf(lot.items[i], aslaas),
        'PENDING',
      ],
  ];
  pw.Widget kv(String l, String v) =>
      pw.Text('$l: $v', style: const pw.TextStyle(fontSize: 8));
  return pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(24),
    build: (ctx) => [
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
            border: pw.Border.all(width: 0.8),
            color: const PdfColor.fromInt(0xFFF3F0D6)),
        child: pw.Text(
          'DRAFT - prepared in DOP Collect. Not an official receipt. The '
          'E-Banking reference and certified schedule are issued by the DOP '
          'portal on submission.',
          style: const pw.TextStyle(fontSize: 8),
          textAlign: pw.TextAlign.center,
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Center(
        child: pw.Column(children: [
          pw.Text('RD INSTALLMENT LIST (agent working copy)',
              style: const pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          kv('Agent Name', agentName.isEmpty ? '-' : agentName),
          kv('Agent Id', agentId.isEmpty ? '-' : agentId),
          kv('Date', date),
          kv('List No. (local)', ref),
          kv('Status', 'Draft - not yet submitted'),
          kv('Total Amount', _amt(lot.totalAmount)),
        ]),
      ),
      pw.SizedBox(height: 12),
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: data,
        border: pw.TableBorder.all(width: 0.5),
        headerStyle:
            const pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 7),
        cellAlignment: pw.Alignment.centerLeft,
        headerAlignment: pw.Alignment.center,
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      ),
      pw.SizedBox(height: 10),
      pw.Text('List No. (local): $ref   Total: ${_amt(lot.totalAmount)}',
          style: const pw.TextStyle(
              fontSize: 8, fontWeight: pw.FontWeight.bold)),
    ],
  );
}

Future<Uint8List> buildLotReportPdf(
  Lot lot, {
  required String agentName,
  required String agentId,
  required String aslaas,
}) async {
  final doc = pw.Document();
  doc.addPage(
      _lotPage(lot, agentName: agentName, agentId: agentId, aslaas: aslaas));
  return doc.save();
}

/// Bundle many lists into ONE PDF, each on its own page — for "download all"
/// or a whole day's batch, so they print/submit together at the counter.
Future<Uint8List> buildBundlePdf(
  List<Lot> lots, {
  required String agentName,
  required String agentId,
  required String aslaas,
}) async {
  final doc = pw.Document();
  for (final lot in lots) {
    doc.addPage(
        _lotPage(lot, agentName: agentName, agentId: agentId, aslaas: aslaas));
  }
  return doc.save();
}
