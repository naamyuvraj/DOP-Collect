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

/// A portal-computed fee. Null means the portal has not said — the list was
/// never submitted — and prints blank rather than a 0.00 the app cannot stand
/// behind. Zero is a real answer and prints as 0.00.
String _fee(int? v) => v == null ? '' : _amt(v);

const _red = PdfColor.fromInt(0xFFC1272D); // India Post red
const _grey = PdfColor.fromInt(0xFFE3E3E3); // header band
const _zebra = PdfColor.fromInt(0xFFF2F2F2); // alternate row shading

/// The portal's own column set, in its order. Nothing else is printed — no Sr
/// no, no local list column, no agent-name block. Labels are left to wrap the
/// way the portal's do.
const _headers = <String>[
  'E-Banking Ref No',
  'RD Account Number',
  'Account Name',
  'RD Denomination',
  'RD Total Deposit Amount',
  'No of Installments',
  'Rebate',
  'Default fee',
  'Bank Name',
  'Cheque Number',
  'SB Account No',
  'ASLAAS Number',
  'Status',
  'Last Created Date & Time',
];

/// Column widths in the portal report's own proportions. Without these the
/// table sizes itself to its content and the long columns (the date stamp, the
/// amounts) starve the rest — that is what makes it read as congested.
/// Each figure is the width in points a column needs so its VALUES never break
/// mid-word at 6.5pt (headers may still wrap over two or three lines, as they
/// do on the portal). They sum to just under the A4 content width.
const _widths = <int, pw.TableColumnWidth>{
  0: pw.FlexColumnWidth(40), // E-Banking Ref No (wraps, as on the portal)
  1: pw.FlexColumnWidth(44), // RD Account Number (wraps)
  2: pw.FlexColumnWidth(48), // Account Name (wraps at the space)
  3: pw.FlexColumnWidth(54), // RD Denomination — "2,000.00 Cr." on one line
  4: pw.FlexColumnWidth(50), // RD Total Deposit Amount — "10,000.00 Cr."
  5: pw.FlexColumnWidth(30), // No of Installments
  6: pw.FlexColumnWidth(33), // Rebate
  7: pw.FlexColumnWidth(32), // Default fee
  8: pw.FlexColumnWidth(29), // Bank Name
  9: pw.FlexColumnWidth(34), // Cheque Number
  10: pw.FlexColumnWidth(35), // SB Account No
  11: pw.FlexColumnWidth(36), // ASLAAS Number
  12: pw.FlexColumnWidth(36), // Status — "Success" on one line
  13: pw.FlexColumnWidth(48), // Last Created Date & Time — date / time
};

/// One list as a page, in the DOP portal's "Recurring Deposit Installment
/// Report" layout — the same columns, spacing and banding, whether or not the
/// list has been submitted yet. The only thing that separates the two is the
/// truth in the fields: an unsubmitted list carries the local `L…` reference
/// and a "Pending" status, never a portal reference or "Success".
pw.MultiPage _lotPage(
  Lot lot, {
  required String agentId,
  required String aslaas,
}) {
  final submitted = lot.referenceNumber != null;
  final ref = lot.referenceNumber ?? lotReference(lot);
  final status = submitted ? 'Success' : 'Pending';
  final when = lot.submittedAt ?? lot.createdAt;
  final dmy = DateFormat('dd-MM-yyyy').format(when);
  final stamp = DateFormat('dd-MM-yyyy hh:mm:ss a').format(when);
  // The portal prints the raw agent id (e.g. "MI8472350100005"), not the
  // "DOP." login prefix the app stores it under.
  final cleanAgent =
      agentId.replaceFirst(RegExp(r'^DOP[.\s]*', caseSensitive: false), '');

  final data = [
    for (final it in lot.items)
      [
        ref,
        it.accountNumber,
        it.customerName,
        _cr(it.denomination),
        // NET of rebate, plus any default fee — what he actually hands over.
        // The reference report reads 11,600 where the gross deposit is 12,000
        // and the rebate is 400.
        _cr(it.netAmount),
        '${it.installments}',
        // The PORTAL's figures, not ours. Blank until it has said — printing a
        // confident 0.00 for a list that was never submitted claims the post
        // office charged no default fee, which we cannot know.
        _fee(it.rebate),
        _fee(it.defaultFee),
        '', // Bank Name (not captured by the app)
        it.chequeNumber ?? '',
        it.bankAccountNumber ?? '',
        aslaasOf(it, aslaas),
        status,
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

  return pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(22),
    build: (ctx) => [
      // Government letterhead — all red, no rule line, matching the portal PDF.
      // (The India Post emblem is intentionally not reproduced.)
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('Govt. of India',
            style: const pw.TextStyle(
                fontSize: 13, fontWeight: pw.FontWeight.bold, color: _red)),
        pw.SizedBox(height: 1),
        pw.Text('Ministry of Communications',
            style: const pw.TextStyle(fontSize: 10, color: _red)),
        pw.SizedBox(height: 1),
        pw.Text('Department of Posts',
            style: const pw.TextStyle(
                fontSize: 15, fontWeight: pw.FontWeight.bold, color: _red)),
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
          crit('Status:', status),
          crit('Cheque No.:', ''),
          crit('Type Of Report:', 'SR'),
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.Text('Search Results', style: const pw.TextStyle(fontSize: 8)),
      pw.SizedBox(height: 8),
      // The portal fills these in — a real report reads "Total Amount: 11600".
      // They used to print blank, on a note claiming the portal left them empty.
      // Rebate and default fee are totalled here too, because that is what the
      // agent reconciles against the cash he handed over.
      pw.Center(
        child: pw.Column(children: [
          crit('Total Amount:', '${lot.totalNetAmount}'),
          crit('Total No Of Records:', '${lot.count}'),
          // Shown so the net total can be checked rather than trusted: gross
          // deposit, minus rebate, plus default fee.
          if (lot.hasPortalFigures) ...[
            crit('Total Deposit:', _amt(lot.totalAmount)),
            crit('Total Rebate:', _amt(lot.totalRebate)),
            crit('Total Default Fee:', _amt(lot.totalDefaultFee)),
          ],
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.TableHelper.fromTextArray(
        headers: _headers,
        data: data,
        border: null, // no gridlines — grey header + zebra rows only
        columnWidths: _widths,
        headerStyle:
            const pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 6.5),
        headerDecoration: const pw.BoxDecoration(color: _grey),
        oddRowDecoration: const pw.BoxDecoration(color: _zebra),
        cellAlignment: pw.Alignment.centerLeft,
        headerAlignment: pw.Alignment.centerLeft,
        // The portal's rows breathe — roughly a blank line above and below.
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        headerPadding:
            const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 7),
      ),
      pw.SizedBox(height: 16),
      // Footer summary — narrower than the main table, as on the portal.
      pw.Container(
        width: 400,
        child: pw.TableHelper.fromTextArray(
          headers: const ['E-Banking Ref No', 'Total Deposit Amount'],
          data: [
            [ref, _amt(lot.totalNetAmount)]
          ],
          border: null,
          columnWidths: const {
            0: pw.FlexColumnWidth(44),
            1: pw.FlexColumnWidth(56),
          },
          headerStyle:
              const pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8),
          headerDecoration: const pw.BoxDecoration(color: _grey),
          cellAlignment: pw.Alignment.centerLeft,
          headerAlignment: pw.Alignment.centerLeft,
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        ),
      ),
    ],
  );
}

/// [agentName] is accepted so existing callers keep working, but it is not
/// printed — the portal's report identifies the agent by id only.
Future<Uint8List> buildLotReportPdf(
  Lot lot, {
  String agentName = '',
  required String agentId,
  required String aslaas,
}) async {
  final doc = pw.Document();
  doc.addPage(_lotPage(lot, agentId: agentId, aslaas: aslaas));
  return doc.save();
}

/// Bundle many lists into ONE PDF, each on its own page — for "download all"
/// or a whole day's batch, so they print/submit together at the counter.
Future<Uint8List> buildBundlePdf(
  List<Lot> lots, {
  String agentName = '',
  required String agentId,
  required String aslaas,
}) async {
  final doc = pw.Document();
  for (final lot in lots) {
    doc.addPage(_lotPage(lot, agentId: agentId, aslaas: aslaas));
  }
  return doc.save();
}
