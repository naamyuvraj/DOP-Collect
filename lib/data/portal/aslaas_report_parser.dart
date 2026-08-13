import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Parses the DOP portal's "ASLAAS Number Report" (Accounts → ASLAAS Number
/// Report → Search) into `accountNumber -> ASLAAS number`.
///
/// The report is a simple two-column table (RD Account Number | ASLAAS Number).
/// Rows where the ASLAAS reads "APPLIED" (not yet assigned by the post office)
/// or is blank are skipped — we only keep real numbers.
class AslaasReportParser {
  static Map<String, String> parse(String html) {
    final out = <String, String>{};
    final dom.Document doc = html_parser.parse(html);
    for (final tr in doc.querySelectorAll('tr')) {
      final cells = tr.querySelectorAll('td');
      if (cells.length < 2) continue;
      // Find the account-number cell; the ASLAAS is the cell right after it.
      for (var i = 0; i + 1 < cells.length; i++) {
        final acc = cells[i].text.replaceAll(RegExp(r'\D'), '');
        if (acc.length < 9 || acc.length > 18) continue; // not an account cell
        final asl = cells[i + 1].text.trim();
        if (asl.isNotEmpty &&
            asl.toUpperCase() != 'APPLIED' &&
            RegExp(r'^[A-Za-z0-9/\-]{3,20}$').hasMatch(asl)) {
          out[acc] = asl;
        }
        break; // one account per row
      }
    }
    return out;
  }
}
