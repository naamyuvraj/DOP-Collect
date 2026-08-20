import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../models/rd_account.dart';

/// One page of the listing, plus what could not be read from it.
///
/// [rejected] counts data rows that looked like accounts but carried a cell
/// this parser could not turn into a real value. They are DROPPED rather than
/// guessed at — see [AgentListParser.parse].
class ParsedPage {
  const ParsedPage(this.accounts, {this.rejected = 0});
  final List<RdAccount> accounts;
  final int rejected;
  static const empty = ParsedPage(<RdAccount>[]);
}

/// Parses the DOP "Agent Inquire and Update" account table (Finacle
/// `AgentRDActSummaryAllListing`) into [RdAccount]s.
///
/// The portal offers no export, so we scrape the rendered table. Real columns
/// (confirmed from a captured page):
///   Select | Account No | Account Name | Denomination | Month Paid Upto |
///   Next RD Installment Due Date
/// Denomination is shown Finacle-style, e.g. "2,000.00 Cr."; dates are
/// dd-MM-yyyy.
///
/// The parser is header-driven: it finds the data table, maps each wanted field
/// to a column index by matching header text, then reads cells by that index —
/// so it survives column reordering and only needs [_HeaderMatch] tuning if the
/// portal relabels a column.
class AgentListParser {
  /// Parse one page of the account list, keeping only rows that are wholly
  /// readable. Pagination is handled by the sync engine, which concatenates
  /// pages.
  ///
  /// A row is REJECTED when its due date will not parse or its denomination
  /// reads as zero. Both used to fall back to a sentinel — `DateTime(2000)` and
  /// `0` — and the sentinel then behaved like real data:
  ///
  ///   * a 01-01-2000 due date makes the account ~320 months overdue, so it
  ///     lands in Defaulters AND About to Freeze and adds its denomination
  ///     times 320 (~Rs 3,19,000 on a Rs 1,000 account) to the To Collect
  ///     total, and
  ///   * a zero denomination makes `CollectionProgress.complete` true the
  ///     moment it is created (`0 >= 0`), so the customer shows as fully paid
  ///     for the cycle and never appears on the round.
  ///
  /// Dropping the row loses one account until the next sync. Keeping it
  /// silently corrupts the dashboard totals and hides a customer from
  /// collection, which is worse and far harder to notice.
  static ParsedPage parse(String htmlSource) {
    final doc = html_parser.parse(htmlSource);
    final table = _findDataTable(doc);
    if (table == null) return ParsedPage.empty;

    final rows = table.querySelectorAll('tr');
    if (rows.isEmpty) return ParsedPage.empty;

    int? headerRowIndex;
    Map<_Field, int?>? cols;
    for (var i = 0; i < rows.length && i < 3; i++) {
      final cells = _cells(rows[i]);
      if (cells.length < 3) continue;
      final mapped = _mapColumns(cells);
      if (mapped[_Field.account] != null &&
          (mapped[_Field.name] != null ||
              mapped[_Field.denomination] != null ||
              mapped[_Field.dueDate] != null ||
              mapped[_Field.monthsPaid] != null)) {
        headerRowIndex = i;
        cols = mapped;
        break;
      }
    }
    if (headerRowIndex == null ||
        cols == null ||
        cols[_Field.account] == null) {
      return ParsedPage.empty;
    }

    final out = <RdAccount>[];
    var rejected = 0;
    for (final row in rows.skip(headerRowIndex + 1)) {
      final cells = _cells(row).map((c) => c.text.trim()).toList();
      final acct = _digits(_at(cells, cols[_Field.account]));
      if (!_looksLikeAccount(acct)) continue;

      // Anything that was not a data row at all was skipped above. From here
      // on the row IS an account, so an unreadable cell is a real failure and
      // gets counted rather than papered over with a sentinel.
      final due = _date(_at(cells, cols[_Field.dueDate]));
      final denomination = _money(_at(cells, cols[_Field.denomination]));
      if (due == null || denomination <= 0) {
        rejected++;
        continue;
      }

      out.add(RdAccount(
        accountNumber: acct,
        customerName: _at(cells, cols[_Field.name])?.trim() ?? '',
        denominationAmount: denomination,
        nextDueDate: due,
        monthsPaid: _intVal(_at(cells, cols[_Field.monthsPaid])),
      ));
    }
    return ParsedPage(out, rejected: rejected);
  }

  /// Accounts only — the shape most callers want.
  static List<RdAccount> parsePage(String htmlSource) =>
      parse(htmlSource).accounts;

  // --- Table location ------------------------------------------------------

  static dom.Element? _findDataTable(dom.Document doc) {
    dom.Element? best;
    var bestScore = 0;
    for (final t in doc.querySelectorAll('table')) {
      final rows = t.querySelectorAll('tr');
      if (rows.isEmpty) continue;
      var maxHeaderScore = 0;
      for (final r in rows.take(3)) {
        final headerText =
            _cells(r).map((c) => c.text.toLowerCase()).join(' | ');
        var score = 0;
        if (_HeaderMatch.account.any(headerText.contains)) score += 3;
        if (_HeaderMatch.name.any(headerText.contains)) score += 1;
        if (_HeaderMatch.denomination.any(headerText.contains)) score += 1;
        if (_HeaderMatch.dueDate.any(headerText.contains)) score += 1;
        if (score > maxHeaderScore) maxHeaderScore = score;
      }
      if (rows.length > 3) maxHeaderScore += 1;
      if (maxHeaderScore > bestScore) {
        bestScore = maxHeaderScore;
        best = t;
      }
    }
    return bestScore >= 3 ? best : null;
  }

  // --- Column mapping ------------------------------------------------------

  static Map<_Field, int?> _mapColumns(List<dom.Element> headerCells) {
    final headers =
        headerCells.map((c) => c.text.toLowerCase().trim()).toList();
    int? find(List<String> patterns, {int? exclude}) {
      for (var i = 0; i < headers.length; i++) {
        if (i == exclude) continue;
        if (patterns.any(headers[i].contains)) return i;
      }
      return null;
    }

    final nameIdx = find(_HeaderMatch.name);
    return {
      // "account name" also contains "account", so match name first and
      // exclude its index from the account lookup.
      _Field.name: nameIdx,
      _Field.account: find(_HeaderMatch.account, exclude: nameIdx),
      _Field.denomination: find(_HeaderMatch.denomination),
      _Field.monthsPaid: find(_HeaderMatch.monthsPaid),
      _Field.dueDate: find(_HeaderMatch.dueDate),
    };
  }

  // --- Cell helpers --------------------------------------------------------

  static List<dom.Element> _cells(dom.Element row) =>
      [...row.querySelectorAll('th'), ...row.querySelectorAll('td')];

  static String? _at(List<String> cells, int? i) =>
      (i == null || i < 0 || i >= cells.length) ? null : cells[i];

  static String _digits(String? s) =>
      s == null ? '' : s.replaceAll(RegExp(r'\D'), '');

  static bool _looksLikeAccount(String digitsOnly) => digitsOnly.length >= 9;

  /// Whole-number count (e.g. "Month Paid Upto" = 67).
  static int _intVal(String? raw) {
    final d = _digits(raw);
    return d.isEmpty ? 0 : int.parse(d);
  }

  /// Parse a Finacle money string to whole rupees: "2,000.00 Cr." -> 2000,
  /// "15,000.00" -> 15000. Drops thousands separators, decimals and Cr./Dr.
  static int _money(String? raw) {
    if (raw == null) return 0;
    final m = RegExp(r'([\d,]+)(?:\.(\d+))?').firstMatch(raw);
    if (m == null) return 0;
    final whole = m.group(1)!.replaceAll(',', '');
    return whole.isEmpty ? 0 : int.parse(whole);
  }

  /// Handles DOP date formats: 30-08-2026, 30/08/2026, 09-Aug-2026, 2026-08-09.
  ///
  /// Null when the cell is empty or in none of those shapes. It used to answer
  /// `DateTime(2000)`, which is not a missing date — it is a date ~320 months
  /// in the past, and every arrears calculation downstream believed it.
  static DateTime? _date(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final s = raw.trim();
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    // dd-MMM-yyyy
    final m1 = RegExp(r'^(\d{1,2})[-/ ]([A-Za-z]{3})[A-Za-z]*[-/ ](\d{4})')
        .firstMatch(s);
    if (m1 != null) {
      final mon = months[m1.group(2)!.toLowerCase()];
      if (mon != null) {
        return DateTime(int.parse(m1.group(3)!), mon, int.parse(m1.group(1)!));
      }
    }
    // dd-MM-yyyy or dd/MM/yyyy
    final m2 = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})').firstMatch(s);
    if (m2 != null) {
      return DateTime(int.parse(m2.group(3)!), int.parse(m2.group(2)!),
          int.parse(m2.group(1)!));
    }
    // yyyy-MM-dd
    final m3 = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(s);
    if (m3 != null) {
      return DateTime(int.parse(m3.group(1)!), int.parse(m3.group(2)!),
          int.parse(m3.group(3)!));
    }
    return null;
  }
}

enum _Field { account, name, denomination, monthsPaid, dueDate }

/// Header-text patterns per field (lowercase substring match). Confirmed
/// against a real capture; extend if a deployment relabels a column.
class _HeaderMatch {
  static const account = [
    'account no',
    'account number',
    'acc no',
    'a/c',
    'account'
  ];
  static const name = ['account name', 'depositor', 'customer name', 'name'];
  static const denomination = ['denomination', 'installment amount', 'deno'];
  static const monthsPaid = ['month paid', 'paid upto', 'inst paid', 'paid'];
  static const dueDate = ['due date', 'installment due', 'next rd', 'due'];
}
