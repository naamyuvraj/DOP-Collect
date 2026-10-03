// Renders a sample Recurring Deposit Installment Report so the layout can be
// eyeballed without a phone, a portal session or real customer data.
//
//   dart run tool/sample_report.dart [out.pdf]
//
// The data is invented. Names, account numbers and ASLAAS numbers are made up
// and deliberately do not resemble anyone's real book.
import 'dart:io';

import 'package:dop_collect/models/lot.dart';
import 'package:dop_collect/screens/lists/lot_report.dart';

void main(List<String> args) async {
  // A realistic spread: mixed denominations, a couple of multi-installment
  // lines, and — unlike the printed copy in hand — non-zero rebate and default
  // fee, because those two columns are the ones with a history of printing
  // 0.00 for everybody.
  const rows = <(String, String, int, int, int?, int?, String)>[
    ('020135920500', 'MD FARMUD', 1000, 1, 0, 0, '804315'),
    ('020135920637', 'SAROJ KUMAR SUMAN', 100, 1, 0, 0, '804686'),
    ('020135920774', 'UMESH KUMAR RAM', 500, 2, 0, 0, '805057'),
    ('020135920911', 'NUSRAT BANO', 100, 1, 0, 0, '805428'),
    ('020135921048', 'RINKU DEVI', 2000, 1, 40, 0, '805799'),
    ('020135921185', 'ANIL KUMAR PASWAN', 100, 3, 0, 0, '806170'),
    ('020135921322', 'SHABANA KHATOON', 1000, 1, 0, 20, '806541'),
    ('020135921459', 'MANOJ SAH', 100, 1, 0, 0, '806912'),
    ('020135921596', 'PREETI KUMARI', 500, 1, 0, 0, '807283'),
    ('020135921733', 'RAJESH RAM', 100, 6, 0, 60, '807654'),
    ('020135921870', 'GUDIYA DEVI', 1000, 1, 20, 0, '808025'),
    ('020135922007', 'SANTOSH YADAV', 15000, 1, 0, 0, '808396'),
  ];

  final lot = Lot(
    createdAt: DateTime(2026, 8, 27, 9, 15),
    mode: 'Cash',
    referenceNumber: 'C343193788',
    submittedAt: DateTime(2026, 8, 27, 11, 42),
    items: [
      for (final r in rows)
        LotItem(
          accountNumber: r.$1,
          customerName: r.$2,
          denomination: r.$3,
          installments: r.$4,
          rebate: r.$5,
          defaultFee: r.$6,
          aslaas: r.$7,
        ),
    ],
  );

  final bytes = await buildLotReportPdf(
    lot,
    agentName: 'Reeta Devi',
    agentId: 'DOP.MI847226011984',
    aslaas: '',
  );
  final path = args.isNotEmpty ? args.first : 'sample_report.pdf';
  File(path).writeAsBytesSync(bytes);
  stdout.writeln('Wrote $path (${(bytes.length / 1024).round()} KB, '
      '${lot.count} rows, total ${lot.totalNetAmount}).');
}
