import 'package:html/parser.dart' as html_parser;

/// Parses the portal's "View Saved Installments" report into
/// `accountNumber -> most recent deposit date`.
///
/// One page load covers every account that appears in the report, instead of
/// opening 465 detail pages. Deliberately shape-tolerant: we have not captured
/// this page, so rather than relying on exact column positions it scans each
/// row for (a) something that looks like an account number and (b) any date,
/// keeping the latest date per account. If the report turns out to be laid out
/// differently, this returns an empty map and the caller falls back.
class SavedInstallmentsParser {
  static Map<String, DateTime> parse(String htmlSource) {
    final out = <String, DateTime>{};
    if (htmlSource.isEmpty) return out;
    final doc = html_parser.parse(htmlSource);

    for (final row in doc.querySelectorAll('tr')) {
      final cells = row
          .querySelectorAll('td')
          .map((c) => c.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (cells.length < 2) continue;

      String? account;
      DateTime? latest;
      for (final cell in cells) {
        // A date must be tested first: "30-08-2026" is 8 digits and could
        // otherwise be mistaken for a short account number.
        final d = _date(cell);
        if (d != null) {
          if (latest == null || d.isAfter(latest)) latest = d;
          continue;
        }
        if (account == null && _looksLikeAccount(cell)) {
          account = cell.replaceAll(RegExp(r'\D'), '');
        }
      }

      if (account == null || latest == null) continue;
      final prev = out[account];
      if (prev == null || latest.isAfter(prev)) out[account] = latest;
    }
    return out;
  }

  /// RD account numbers are long digit runs (with optional spaces/dashes).
  static bool _looksLikeAccount(String raw) {
    if (!RegExp(r'^[\d\s-]+$').hasMatch(raw)) return false;
    return raw.replaceAll(RegExp(r'\D'), '').length >= 9;
  }

  /// dd-MM-yyyy, dd/MM/yyyy, dd-MMM-yyyy and yyyy-MM-dd.
  static DateTime? _date(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final m1 = RegExp(r'^(\d{1,2})[-/ ]([A-Za-z]{3})[A-Za-z]*[-/ ](\d{4})$')
        .firstMatch(s);
    if (m1 != null) {
      final mon = months[m1.group(2)!.toLowerCase()];
      if (mon != null) {
        return DateTime(int.parse(m1.group(3)!), mon, int.parse(m1.group(1)!));
      }
    }
    final m2 = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(s);
    if (m2 != null) {
      final mo = int.parse(m2.group(2)!);
      final d = int.parse(m2.group(1)!);
      if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
        return DateTime(int.parse(m2.group(3)!), mo, d);
      }
    }
    final m3 = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$').firstMatch(s);
    if (m3 != null) {
      return DateTime(int.parse(m3.group(1)!), int.parse(m3.group(2)!),
          int.parse(m3.group(3)!));
    }
    return null;
  }
}
