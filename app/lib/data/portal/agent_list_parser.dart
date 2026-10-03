import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../models/rd_account.dart';
import 'portal_dom.dart';

/// An account the portal lists with **no next installment due** — it has run
/// its full term.
///
/// Deliberately NOT an [RdAccount]: that model requires a `nextDueDate`, and
/// the absence of one is exactly what makes this row matured. Inventing a date
/// to fit the model is what the old `DateTime(2000)` sentinel did, and it put
/// accounts 320 months in arrears and inflated the dashboard by lakhs. The
/// caller stamps these closed with the sync date instead, which is a fact it
/// actually knows.
class MaturedRow {
  const MaturedRow({
    required this.accountNumber,
    required this.customerName,
    required this.denominationAmount,
    required this.monthsPaid,
  });
  final String accountNumber;
  final String customerName;
  final int denominationAmount;
  final int monthsPaid;
}

/// One page of the listing, plus what could not be read from it.
///
/// [rejected] counts data rows that looked like accounts but carried a cell
/// this parser could not turn into a real value. They are DROPPED rather than
/// guessed at — see [AgentListParser.parse].
///
/// [matured] is different and must not be lumped in with it: the portal leaves
/// "Next RD Installment Due Date" **blank** once an account reaches its
/// 60-month term, and on a real capture that was 2 rows in 10. Those are
/// perfectly good rows about perfectly real customers; the parser used to count
/// them as failures, which made a routine month of maturities look like the
/// table had gone bad.
///
/// Each account carries `serial` = its **1-based row position in this
/// document**, counted over EVERY data row — maturities and rejects included.
///
/// That distinction is the whole point. `serial` is the app's short code AND
/// the index that lets a list build jump straight to the portal page holding an
/// account (`(serial - 1) ~/ rowsPerPage + 1`). Numbering only the rows we kept
/// makes every account after the first maturity sit one row too early, so a
/// book with three maturities near the top sends ~30% of jumps to the page
/// before the right one — and every miss costs a full 47-page scan.
class ParsedPage {
  const ParsedPage(this.accounts,
      {this.rejected = 0,
      this.rejectedAccounts = const <String>{},
      this.maturedRows = const <MaturedRow>[]});

  /// The account numbers of the [rejected] rows.
  ///
  /// A rejected row is a REAL account the portal listed; only one of its cells
  /// would not read. The sync must therefore be able to say "I saw this
  /// account", because a complete sync closes every account it did not see —
  /// so without these, one unreadable denomination silently closed a live
  /// customer, dropped him off the collection round, and filed him under
  /// Matured Accounts with whatever figures he last had.
  final Set<String> rejectedAccounts;

  /// Readable accounts, each stamped with its row position (see above).
  final List<RdAccount> accounts;
  final int rejected;

  /// The matured rows themselves. They used to be counted and thrown away,
  /// which meant the agent's book silently held fewer customers than the
  /// portal did, with nothing on screen to say which ones were missing.
  final List<MaturedRow> maturedRows;
  int get matured => maturedRows.length;
  static const empty = ParsedPage(<RdAccount>[]);

  /// True when the page yielded nothing at all — no accounts, no rejects, no
  /// maturities. That means the table did not render, which is a failure; a
  /// page that yielded only maturities is a success and must not read as one.
  bool get isEmpty => accounts.isEmpty && rejected == 0 && matured == 0;

  /// Every data row the page held, however it was classified.
  int get rows => accounts.length + rejected + matured;
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
    // Finacle labels every cell with a stable per-field id. Use those when they
    // are there; fall back to reading the table by column position when they
    // are not.
    final structured = _parseByRowIds(doc);
    if (structured != null) return structured;
    return _parseByTable(doc);
  }

  static ParsedPage _parseByTable(dom.Document doc) {
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
    final rejectedAccounts = <String>{};
    final maturedRows = <MaturedRow>[];
    // Position in the table, counted over every data row — including the ones
    // dropped below. See [ParsedPage].
    var rowIndex = 0;
    for (final row in rows.skip(headerRowIndex + 1)) {
      final cells = _cells(row).map((c) => c.text.trim()).toList();
      final acct = _digits(_at(cells, cols[_Field.account]));
      if (!_looksLikeAccount(acct)) continue;
      rowIndex++;

      // Anything that was not a data row at all was skipped above. From here
      // on the row IS an account, so an unreadable cell is a real failure and
      // gets counted rather than papered over with a sentinel.
      final rawDue = _clean(_at(cells, cols[_Field.dueDate]) ?? '');
      final due = _date(rawDue);
      final denomination = _money(_at(cells, cols[_Field.denomination]));
      if (denomination <= 0) {
        rejected++;
        rejectedAccounts.add(acct);
        continue;
      }
      if (due == null) {
        // Blank means the account has reached term, not that the cell failed
        // to parse. Keep the row — see [ParsedPage.maturedRows].
        if (rawDue.isEmpty) {
          maturedRows.add(MaturedRow(
            accountNumber: acct,
            customerName: _at(cells, cols[_Field.name])?.trim() ?? '',
            denominationAmount: denomination,
            monthsPaid: _intVal(_at(cells, cols[_Field.monthsPaid])),
          ));
        } else {
          rejected++;
          rejectedAccounts.add(acct);
        }
        continue;
      }

      out.add(RdAccount(
        accountNumber: acct,
        customerName: _at(cells, cols[_Field.name])?.trim() ?? '',
        denominationAmount: denomination,
        nextDueDate: due,
        monthsPaid: _intVal(_at(cells, cols[_Field.monthsPaid])),
        serial: rowIndex,
      ));
    }
    return ParsedPage(out,
        rejected: rejected,
        rejectedAccounts: rejectedAccounts,
        maturedRows: maturedRows);
  }

  /// Accounts only — the shape most callers want.
  static List<RdAccount> parsePage(String htmlSource) =>
      parse(htmlSource).accounts;

  // --- Structured read (preferred) -----------------------------------------

  /// Read the rows straight off Finacle's own per-field element ids.
  ///
  /// Every cell on the listing carries a stable id of the form
  /// `HREF_CustomAgentRDAccountFG.<FIELD>_ALL_ARRAY[i]` — the account number on
  /// an `<a>`, the rest on `<span class="searchsimpletext">`. Reading those is
  /// strictly better than reading by column position: it does not care what
  /// order the columns are in, whether the leading "Select" checkbox column is
  /// there, or how the headers are worded. Column-position parsing is kept as
  /// the fallback for the day the portal is rebuilt and these ids change.
  ///
  /// Returns null when the page carries no such ids at all, so the caller can
  /// fall back rather than mistake "different markup" for "no accounts".
  static ParsedPage? _parseByRowIds(dom.Document doc) {
    const prefix = PortalDom.rowIdPrefix;
    final byId = <String, String>{};
    for (final el in [
      ...doc.querySelectorAll('a'),
      ...doc.querySelectorAll('span'),
    ]) {
      final id = el.id;
      if (id.startsWith(prefix)) byId[id] = _clean(el.text);
    }
    if (byId.isEmpty) return null;

    String? cell(String field, int i) => byId['$prefix$field[$i]'];

    // Row indices are 0-based and contiguous, but read them off the ids rather
    // than assuming — a page with fewer than the usual ten rows is the last one.
    final indices = <int>{};
    final idxRe =
        RegExp('^${RegExp.escape(prefix)}${PortalDom.accountNumberArray}'
            r'\[(\d+)\]$');
    for (final id in byId.keys) {
      final m = idxRe.firstMatch(id);
      if (m != null) indices.add(int.parse(m.group(1)!));
    }
    if (indices.isEmpty) return null;

    final ordered = indices.toList()..sort();
    final out = <RdAccount>[];
    var rejected = 0;
    final rejectedAccounts = <String>{};
    final maturedRows = <MaturedRow>[];

    for (final i in ordered) {
      final acct = _digits(cell(PortalDom.accountNumberArray, i));
      if (!_looksLikeAccount(acct)) continue;

      final denomination = _money(cell(PortalDom.depositAmountArray, i));
      final rawDue = cell(PortalDom.nextDueDateArray, i) ?? '';
      final due = _date(rawDue);

      // A denomination that will not read is a broken row — every arrears sum
      // downstream is denomination times months, so a zero there quietly marks
      // the customer fully paid and drops him off the round.
      if (denomination <= 0) {
        rejected++;
        rejectedAccounts.add(acct);
        continue;
      }
      // A BLANK due date is not a broken row. The portal empties that cell when
      // an account has reached term, so this is the parser being told "nothing
      // further is due", not the parser failing.
      if (due == null) {
        if (rawDue.trim().isEmpty) {
          maturedRows.add(MaturedRow(
            accountNumber: acct,
            customerName: cell(PortalDom.accountNameArray, i)?.trim() ?? '',
            denominationAmount: denomination,
            monthsPaid: _intVal(cell(PortalDom.monthPaidUptoArray, i)),
          ));
        } else {
          rejected++;
          rejectedAccounts.add(acct);
        }
        continue;
      }

      out.add(RdAccount(
        accountNumber: acct,
        customerName: cell(PortalDom.accountNameArray, i)?.trim() ?? '',
        denominationAmount: denomination,
        nextDueDate: due,
        monthsPaid: _intVal(cell(PortalDom.monthPaidUptoArray, i)),
        // Finacle's own row index — see [ParsedPage] on why position must be
        // read off the document rather than counted from the kept rows.
        serial: i + 1,
      ));
    }
    return ParsedPage(out,
        rejected: rejected,
        rejectedAccounts: rejectedAccounts,
        maturedRows: maturedRows);
  }

  /// Collapse the portal's whitespace, including the `&nbsp;` it puts in an
  /// empty due-date cell — which arrives as U+00A0 and is not caught by
  /// `String.trim()` in every position we care about.
  static String _clean(String s) =>
      s.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

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
