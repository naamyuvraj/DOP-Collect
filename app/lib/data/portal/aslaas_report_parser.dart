import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// One read of the ASLAAS report, with the rows it could not use counted
/// rather than dropped.
///
/// [rows] is EVERY account row the document held — including the ones with no
/// usable number. That count is what lets a caller check a one-request read of
/// the whole report against the portal's own "Displaying 1 - 10 of 692 results"
/// banner: [numbers] alone can't do it, because a report where half the
/// accounts read APPLIED is a short map on a complete read.
class AslaasReport {
  const AslaasReport(this.numbers, {this.rows = 0, this.applied = 0});

  /// `accountNumber -> ASLAAS number`, real numbers only.
  final Map<String, String> numbers;

  /// Account rows seen, whatever their ASLAAS cell said.
  final int rows;

  /// Rows whose number the post office has not issued yet ("APPLIED"/blank).
  final int applied;

  static const empty = AslaasReport(<String, String>{});
}

/// Parses the DOP portal's "ASLAAS Number Report" (Accounts → ASLAAS Number
/// Report → Search) into `accountNumber -> ASLAAS number`.
///
/// The report is a simple two-column table (RD Account Number | ASLAAS Number).
/// Rows where the ASLAAS reads "APPLIED" (not yet assigned by the post office)
/// or is blank are skipped — we only keep real numbers.
///
/// The same parse serves one paginated page and the whole-report print preview:
/// the preview is the same table with every row in it.
class AslaasReportParser {
  static Map<String, String> parse(String html) => read(html).numbers;

  static AslaasReport read(String html) {
    final out = <String, String>{};
    var rows = 0;
    var applied = 0;
    final dom.Document doc = html_parser.parse(html);
    for (final tr in doc.querySelectorAll('tr')) {
      final cells = tr.querySelectorAll('td');
      if (cells.length < 2) continue;
      // Find the account-number cell; the ASLAAS is the cell right after it.
      for (var i = 0; i + 1 < cells.length; i++) {
        final acc = cells[i].text.replaceAll(RegExp(r'\D'), '');
        if (acc.length < 9 || acc.length > 18) continue; // not an account cell
        rows++;
        final asl = cells[i + 1].text.trim();
        if (asl.isNotEmpty &&
            asl.toUpperCase() != 'APPLIED' &&
            RegExp(r'^[A-Za-z0-9/\-]{3,20}$').hasMatch(asl)) {
          out[acc] = asl;
        } else {
          applied++;
        }
        break; // one account per row
      }
    }
    return AslaasReport(out, rows: rows, applied: applied);
  }
}
