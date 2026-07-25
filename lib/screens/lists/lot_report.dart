import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/lot.dart';
import '../../util/format.dart';

/// Builds the "Recurring Deposit Installment Report" (the DOP list receipt) for
/// a saved lot — the same layout the portal prints — so the agent can print,
/// share, or WhatsApp it. A local list-reference number is derived from the lot
/// (the real E-Banking ref is assigned by the portal on submission).
String lotReference(Lot lot) =>
    'C${(lot.createdAt.millisecondsSinceEpoch % 1000000000).toString().padLeft(9, '0')}';

/// Plain-text summary for WhatsApp / share-as-text.
String lotReportText(Lot lot, {String aslaas = ''}) {
  final ref = lotReference(lot);
  final b = StringBuffer()
    ..writeln('Recurring Deposit Installment Report')
    ..writeln('List Ref No: $ref')
    ..writeln('Date: ${DateFormat('dd-MMM-yyyy').format(lot.createdAt)}')
    ..writeln('ASLAAS: ${aslaas.isEmpty ? '-' : aslaas}')
    ..writeln('Accounts: ${lot.count}  Total: ${inr(lot.totalAmount)}')
    ..writeln('');
  for (var i = 0; i < lot.items.length; i++) {
    final it = lot.items[i];
    b.writeln('${i + 1}. ${it.customerName}  ${it.accountNumber}  '
        'x${it.installments}  ${inr(it.amount)}');
  }
  return b.toString();
}

Future<Uint8List> buildLotReportPdf(
  Lot lot, {
  required String agentName,
  required String agentId,
  required String aslaas,
}) async {
  final doc = pw.Document();
  final ref = lotReference(lot);
  final date = DateFormat('dd-MMM-yyyy').format(lot.createdAt);

  final headers = <String>[
    'Sr\nno',
    'E-Banking\nRef No',
    'Rd Account\nNumber',
    'Account\nName',
    'RD\nDenomination',
    'RD Total\nDeposit Amount',
    'No of\nInstallment',
    'Rebate',
    'Default\nFee',
    'Aslaas\nNo.',
    'Status',
  ];

  final data = <List<String>>[];
  for (var i = 0; i < lot.items.length; i++) {
    final it = lot.items[i];
    data.add([
      '${i + 1}',
      ref,
      it.accountNumber,
      it.customerName,
      '${it.denomination}',
      '${it.amount}',
      '${it.installments}',
      '0.00',
      '0.00',
      aslaas.isEmpty ? '-' : aslaas,
      'APPLIED',
    ]);
  }

  pw.Widget kv(String label, String value) => pw.Text('$label: $value',
      style: const pw.TextStyle(fontSize: 8));

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => [
        pw.Center(
          child: pw.Column(children: [
            pw.Text('Department of Posts',
                style: const pw.TextStyle(
                    fontSize: 11, fontWeight: pw.FontWeight.bold)),
            pw.Text('Ministry of Communications, Government of India',
                style: const pw.TextStyle(fontSize: 8)),
            pw.SizedBox(height: 12),
            pw.Text('RECURRING DEPOSIT INSTALLMENT REPORT',
                style: const pw.TextStyle(
                    fontSize: 13, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            kv('Agent Name', agentName.isEmpty ? '-' : agentName),
            kv('Agent Id', agentId.isEmpty ? '-' : agentId),
            kv('From Date', '$date To Date: $date'),
            kv('List Reference No', ref),
            kv('Status', 'Success'),
            kv('Total Amount', '${lot.totalAmount}'),
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
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('E-Banking Ref No: $ref',
                style: const pw.TextStyle(
                    fontSize: 8, fontWeight: pw.FontWeight.bold)),
            pw.Text('Total Deposit Amount: ${lot.totalAmount}',
                style: const pw.TextStyle(
                    fontSize: 8, fontWeight: pw.FontWeight.bold)),
          ],
        ),
      ],
    ),
  );
  return doc.save();
}
