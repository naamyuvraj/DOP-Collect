import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/lot.dart';
import '../../util/format.dart';
import 'india_post_emblem.dart';

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
    ..writeln('Accounts: ${lot.count}  Total: ${inr(lot.totalNetAmount)}')
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

/// Finacle-style money: "1,000.00 Cr." - Indian grouping, two decimals, and
/// the credit marker the portal prints. The columns that carry a DEPOSIT use
/// this; Rebate and Default Fee stay bare decimals, as on the printed copy.
String _cr(num v) => '${NumberFormat('#,##,##0.00').format(v)} Cr.';

/// The same figure without the marker, for the header block and the footer.
String _amt(num v) => NumberFormat('#,##,##0.00').format(v);

/// A portal-computed fee. Null means the portal has not said — the list was
/// never submitted — and prints blank rather than a 0.00 the app cannot stand
/// behind. Zero is a real answer and prints as 0.00.
String _fee(int? v) => v == null ? '' : _amt(v);

const _red = PdfColor.fromInt(0xFFC1272D); // India Post red
const _grey = PdfColor.fromInt(0xFFE3E3E3); // header band

/// The report's column set, in the portal's order.
///
/// Rebuilt against a PRINTED report the agent files at the counter, which is a
/// leaner variant than the PDF this file was first written from: no Bank Name,
/// Cheque Number, SB Account No or Last Created Date & Time, and a row number
/// down the left. Those four only carry information on a cheque list, so they
/// are added back when — and only when — the list is a cheque one. Printing an
/// always-empty Cheque Number column on a cash list is four columns of width
/// spent saying nothing, which is what made the old table read as congested.
///
/// Labels are the printed report's own, down to "No of Installment" being
/// singular and "Aslaas No." not matching the portal's own "ASLAAS Number"
/// elsewhere. They are what the counter clerk reads; our spelling preferences
/// do not come into it.
List<String> reportHeaders({required bool cheque}) => <String>[
      '',
      'E-Banking Ref No',
      'Rd Account Number',
      'Account Name',
      'RD Denomination',
      'RD Total Deposit Amount',
      'No of Installment',
      'Rebate',
      'Default Fee',
      if (cheque) ...['Bank Name', 'Cheque Number', 'SB Account No'],
      'Aslaas No.',
      'Status',
    ];

/// Proportional widths, so the table fits the page whether or not the three
/// cheque columns are present.
Map<int, pw.TableColumnWidth> _widthsFor({required bool cheque}) {
  // Sized from what actually has to FIT, not by eye. Two constraints bind:
  //
  //   * a header word cannot wrap through itself - "Denomination" and
  //     "Installment" are single words needing ~41pt and ~37pt at this size,
  //     and a column narrower than that renders "Denominatio/n";
  //   * the widest value in the money columns is now "15,000.00 Cr." at ~44pt,
  //     because those columns carry the Cr. marker.
  //
  // So the two money columns and the installment column get a floor, and the
  // rest share what is left. The cheque layout has three more columns on the
  // same page, hence its own set - proportions, so both always fill the width.
  // Every column carries a floor: the widest thing that must sit on ONE line,
  // plus 8pt of padding. A single word cannot wrap through itself, so a column
  // narrower than its longest header word renders "Reb/ate".
  final w = cheque
      ? <double>[
          30, // row no
          70, // E-Banking Ref No   floor "C343193788"      ~47
          90, // Rd Account Number  HIGHLIGHTED, 12 digits  ~64
          80, // Account Name
          70, // RD Denomination    floor "15,000.00 Cr."   ~53
          85, // RD Total Deposit   HIGHLIGHTED             ~63
          55, // No of Installment  floor "Installment"     ~42
          45, // Rebate
          50, // Default Fee
          50, // Bank Name
          60, // Cheque Number
          65, // SB Account No      floor "3766788625"      ~46
          60, // Aslaas No.
          55, // Status             floor "Success"         ~34
        ]
      : <double>[
          46, // row no - three digits
          115, // E-Banking Ref No  floor "C343193788"      ~47
          150, // Rd Account Number HIGHLIGHTED, 12 digits  ~64
          100, // Account Name
          100, // RD Denomination   floor "15,000.00 Cr."   ~53
          140, // RD Total Deposit  HIGHLIGHTED             ~63
          85, // No of Installment  floor "Installment"     ~42
          55, // Rebate
          60, // Default Fee
          84, // Aslaas No.
          78, // Status
        ];
  return {for (var i = 0; i < w.length; i++) i: pw.FlexColumnWidth(w[i])};
}

/// One list as a page, in the DOP portal's "Recurring Deposit Installment
/// Report" layout — the same columns, spacing and banding, whether or not the
/// list has been submitted yet. The only thing that separates the two is the
/// truth in the fields: an unsubmitted list carries the local `L…` reference
/// and a "Pending" status, never a portal reference or "Success".
/// Whether this list needs the three cheque columns.
///
/// Driven by the DATA, not by `lot.mode`: a list saved as a cheque mode whose
/// cheque numbers were never filled in has nothing to put in those columns, and
/// three empty columns cost width the other eleven need.
bool reportIsCheque(Lot lot) => lot.items.any((i) =>
    (i.chequeNumber ?? '').isNotEmpty ||
    (i.bankAccountNumber ?? '').isNotEmpty);

/// The table body, one list of cells per account, in [reportHeaders] order.
///
/// Public because the column count is the one thing in this file that fails
/// invisibly: a row a cell short of its header throws from inside the pdf
/// package with a message naming neither the column nor the list.
List<List<String>> reportRows(Lot lot, {required String aslaas}) {
  final cheque = reportIsCheque(lot);
  final submitted = lot.referenceNumber != null;
  final ref = lot.referenceNumber ?? lotReference(lot);
  final status = submitted ? 'Success' : 'Pending';
  return <List<String>>[
    for (var i = 0; i < lot.items.length; i++)
      () {
        final it = lot.items[i];
        return <String>[
          '${i + 1}',
          ref,
          it.accountNumber,
          it.customerName,
          _cr(it.denomination),
          // NET of rebate, plus any default fee — what he actually hands over.
          // Verified against a real report reading 11,600 where the gross
          // deposit is 12,000 and the rebate is 400.
          _cr(it.netAmount),
          '${it.installments}',
          // The PORTAL's figures, not ours. Blank until it has said — printing
          // a confident 0.00 for a list that was never submitted claims the
          // post office charged no default fee, which we cannot know.
          _fee(it.rebate),
          _fee(it.defaultFee),
          if (cheque) ...[
            '', // Bank Name (not captured by the app)
            it.chequeNumber ?? '',
            it.bankAccountNumber ?? '',
          ],
          aslaasOf(it, aslaas),
          status,
        ];
      }(),
  ];
}

pw.MultiPage _lotPage(
  Lot lot, {
  required String agentName,
  required String agentId,
  required String aslaas,
}) {
  final submitted = lot.referenceNumber != null;
  final ref = lot.referenceNumber ?? lotReference(lot);
  final status = submitted ? 'Success' : 'Pending';
  final when = lot.submittedAt ?? lot.createdAt;
  // "26-Aug-2026", as printed. Not 26-08-2026 — the counter reads these.
  final dmy = DateFormat('dd-MMM-yyyy').format(when);
  final cheque = reportIsCheque(lot);

  // The printed report shows the id EXACTLY as the portal holds it, prefix and
  // all — "DOP.MI847226011984". This used to strip the "DOP." on the belief
  // that the portal omitted it; the printed copy says otherwise, and an id that
  // does not match the one on file is worse than no id.
  final printedAgentId = agentId.trim();

  final data = reportRows(lot, aslaas: aslaas);

  /// Which columns hold a figure. Numbers read down a column far better set
  /// bold and hard right: the decimal points line up, so the eye can compare
  /// two rows without reading either. Names and references stay left.
  final numeric = <int>{
    0, 4, 5, 6, 7, 8, // row no, denomination, total, installments, rebate, fee
    if (cheque) 11, // SB Account No
  };

  // The two columns the agent actually reads at the counter: WHICH account, and
  // HOW MUCH for it. Everything else on the row is context he checks only when
  // something looks wrong, so those two are set larger and the rest stay small.
  // Set every column large and none of them stands out.
  const account = 2;
  const perAccount = 5;
  // One size for both layouts now that the cheque report is landscape.
  const big = 8.4;

  pw.Widget cell(String text, int col, {required bool header}) {
    final isNum = numeric.contains(col) && !header;
    final highlight = !header && (col == account || col == perAccount);
    return pw.Container(
      alignment: isNum ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      padding: pw.EdgeInsets.symmetric(
          horizontal: 4, vertical: highlight ? 5 : 6),
      child: pw.Text(
        text,
        textAlign: isNum ? pw.TextAlign.right : pw.TextAlign.left,
        style: pw.TextStyle(
          fontSize: header ? 6.4 : (highlight ? big : 6.8),
          // Bold for the headers, for the two highlighted columns, and for the
          // denomination that explains the amount beside it.
          fontWeight: header || highlight || col == 4
              ? pw.FontWeight.bold
              : pw.FontWeight.normal,
        ),
      ),
    );
  }

  /// One "Label   value" line of the header block, with the labels sharing a
  /// right edge so the values line up down a single column. Ragged values were
  /// what made this block read as typed-out rather than printed.
  pw.Widget crit(String label, String value, {bool strong = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.SizedBox(
                width: 74,
                child: pw.Text(label,
                    textAlign: pw.TextAlign.right,
                    style: const pw.TextStyle(fontSize: 8.5)),
              ),
              pw.SizedBox(width: 8),
              pw.Text(value,
                  style: pw.TextStyle(
                      fontSize: 8.5,
                      fontWeight:
                          strong ? pw.FontWeight.bold : pw.FontWeight.normal)),
            ]),
      );

  final headers = reportHeaders(cheque: cheque);

  return pw.MultiPage(
    // A cheque list carries FOURTEEN columns. Shaving fonts to fit them across
    // 543pt of A4 portrait is how "Rebate" became "Reb/ate", "Success" became
    // "Succes/s" and a cheque number wrapped mid-digit - a table nobody can
    // read at a counter. Landscape gives 790pt, which fits all fourteen at the
    // same size the cash report uses. A cash list stays portrait.
    pageFormat: cheque ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(26, 26, 26, 30),
    build: (ctx) => [
      // --- Letterhead ------------------------------------------------------
      // Emblem to the left of the department lines, as printed. Reproduced ONLY
      // on a submitted list: that list has a real E-Banking reference from the
      // portal and describes money that actually moved. An unsubmitted list is
      // a working document the agent made on his phone, and dressing one in a
      // government mark would make a plan look like a record.
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        if (submitted && hasIndiaPostEmblem) ...[
          pw.SizedBox(
            width: 62,
            child: pw.Image(
                pw.MemoryImage(base64Decode(indiaPostEmblemBase64))),
          ),
          pw.SizedBox(width: 12),
        ],
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('Department of Posts',
              style: const pw.TextStyle(
                  fontSize: 10, color: _red, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 1),
          pw.Text('Ministry of Communications',
              style: const pw.TextStyle(fontSize: 9, color: _red)),
          pw.SizedBox(height: 1),
          pw.Text('Government of India',
              style: const pw.TextStyle(fontSize: 9, color: _red)),
        ]),
      ]),
      pw.SizedBox(height: 10),
      // A hairline under the letterhead. It is what separates "who issued
      // this" from "what it says", and it is the cheapest thing on the page.
      pw.Divider(height: 1, thickness: 0.7, color: _red),
      pw.SizedBox(height: 12),

      // --- Title + criteria block ------------------------------------------
      pw.Center(
        child: pw.Text('RECURRING DEPOSIT INSTALLMENT REPORT',
            style: const pw.TextStyle(
                fontSize: 12.5,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 0.4)),
      ),
      pw.SizedBox(height: 12),
      pw.Center(
        child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              if (agentName.trim().isNotEmpty)
                crit('Agent Name:', agentName.trim()),
              crit('Agent Id:', printedAgentId.isEmpty ? '-' : printedAgentId),
              crit('From Date:', dmy),
              crit('To Date:', dmy),
              crit('List:', ref, strong: true),
              crit('Status:', status),
              crit('Total:', _cr(lot.totalNetAmount), strong: true),
            ]),
      ),
      pw.SizedBox(height: 14),

      // --- The table -------------------------------------------------------
      // Built by hand rather than with TableHelper.fromTextArray, which takes
      // ONE cell style for the whole grid. The money columns need to be bold
      // and right-aligned while the names stay plain and left - that is the
      // difference between a grid you can scan and one you have to read.
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey700, width: 0.5),
        columnWidths: _widthsFor(cheque: cheque),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _grey),
            repeat: true, // header repeats when a long list spills over
            children: [
              for (var c = 0; c < headers.length; c++)
                cell(headers[c], c, header: true),
            ],
          ),
          for (final row in data)
            pw.TableRow(children: [
              for (var c = 0; c < row.length; c++)
                cell(row[c], c, header: false),
            ]),
        ],
      ),
      pw.SizedBox(height: 16),

      // --- Footer total ----------------------------------------------------
      //
      // Set larger than the rest of the page on purpose. These are the two
      // things read out loud at the counter — the reference the clerk matches
      // and the cash figure that has to agree with the till — and they were
      // the same 8.5pt as every other cell, so the eye had to hunt for them on
      // a sheet that is otherwise all numbers.
      pw.Row(children: [
        pw.Container(
          width: 340,
          child: pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey700, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(48),
              1: pw.FlexColumnWidth(52),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: _grey),
                children: [
                  for (final h in const [
                    'E-Banking Ref No',
                    'Total Deposit Amount'
                  ])
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 7, vertical: 7),
                      child: pw.Text(h,
                          style: const pw.TextStyle(
                              fontSize: 9.5,
                              fontWeight: pw.FontWeight.bold)),
                    ),
                ],
              ),
              pw.TableRow(children: [
                pw.Padding(
                  padding:
                      const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 7),
                  child: pw.Text(ref,
                      style: const pw.TextStyle(
                          fontSize: 10.5, fontWeight: pw.FontWeight.bold)),
                ),
                pw.Container(
                  alignment: pw.Alignment.centerRight,
                  padding:
                      const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 7),
                  child: pw.Text(_cr(lot.totalNetAmount),
                      style: const pw.TextStyle(
                          fontSize: 10.5, fontWeight: pw.FontWeight.bold)),
                ),
              ]),
            ],
          ),
        ),
      ]),

      // ASCII only in anything that reaches the PDF: the built-in Helvetica has
      // no U+2014 and paints an em dash as a solid black box. Caught in a
      // rendered page, not in review - `flutter analyze` has nothing to say
      // about a glyph the font lacks.
      if (!submitted) ...[
        pw.SizedBox(height: 16),
        pw.Text(
            'DRAFT - prepared in DOP Collect. Not a Department of Posts '
            'record. No payment has been made; submit on the DOP portal for '
            'the E-Banking reference.',
            style: const pw.TextStyle(fontSize: 8, color: _red)),
      ],
    ],
  );
}

/// [agentName] IS printed now. The earlier note here said the portal's report
/// identifies the agent by id only; the printed copy the agent files carries
/// "Agent Name: Reeta Devi" above the id, so it does both.
Future<Uint8List> buildLotReportPdf(
  Lot lot, {
  String agentName = '',
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
  String agentName = '',
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
