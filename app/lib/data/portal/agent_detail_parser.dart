import 'package:html/parser.dart' as html_parser;

/// Parsed fields from a single "ViewRDAccountDetails" page.
class AccountDetail {
  final String accountNumber;
  final DateTime? openingDate;
  final int? totalDeposit;
  final int? pendingInstallments;
  final int? defaultInstallments;
  final DateTime? lastDepositDate;

  const AccountDetail({
    required this.accountNumber,
    this.openingDate,
    this.totalDeposit,
    this.pendingInstallments,
    this.defaultInstallments,
    this.lastDepositDate,
  });

  /// Any field parsed at all. Deliberately broad: a page that yields only the
  /// last-deposit date is still worth saving — gating on opening/total alone
  /// silently threw those records away.
  bool get hasData =>
      openingDate != null ||
      totalDeposit != null ||
      lastDepositDate != null ||
      pendingInstallments != null ||
      defaultInstallments != null;
}

/// Reads the account detail page. Label-driven: finds each label cell and takes
/// the adjacent value, so it survives Finacle's verbose markup. Confirmed
/// labels: Account No, Account Opening Date, Total Deposit Amount, Month Paid Up
/// to, Date of Last Deposit, Default installments, Pending installments.
class AgentDetailParser {
  /// Build a detail from already-extracted raw strings.
  ///
  /// Used by the fast path, where the DOM walk happens in JavaScript (so only a
  /// few short strings cross the bridge instead of whole pages). Value parsing
  /// stays here so string→date/money conversion has ONE implementation.
  static AccountDetail fromFields({
    required String account,
    String? openingDate,
    String? totalDeposit,
    String? pendingInstallments,
    String? defaultInstallments,
    String? lastDepositDate,
  }) =>
      AccountDetail(
        accountNumber: _digits(account),
        openingDate: _date(openingDate),
        totalDeposit: _money(totalDeposit),
        pendingInstallments: _int(pendingInstallments),
        defaultInstallments: _int(defaultInstallments),
        lastDepositDate: _date(lastDepositDate),
      );

  static AccountDetail parse(String htmlSource) {
    final doc = html_parser.parse(htmlSource);
    // Collect all short text cells in document order.
    final cells = <String>[];
    for (final el in doc.querySelectorAll('td, th, span, label, div')) {
      final t = el.text.trim();
      if (t.isNotEmpty && t.length < 60 && !t.contains('\n')) cells.add(t);
    }

    String? valueAfter(List<String> labels) {
      for (var i = 0; i < cells.length - 1; i++) {
        final c = cells[i].toLowerCase();
        if (labels.any((l) => c.contains(l))) {
          // Return the next non-empty cell that isn't itself a label echo.
          for (var j = i + 1; j < cells.length && j <= i + 3; j++) {
            final v = cells[j].trim();
            if (v.isNotEmpty && v != cells[i]) return v;
          }
        }
      }
      return null;
    }

    return AccountDetail(
      accountNumber: _digits(valueAfter(['account no'])),
      openingDate: _date(valueAfter(['account opening date', 'opening date'])),
      totalDeposit: _money(valueAfter(['total deposit'])),
      pendingInstallments: _int(valueAfter(['pending installment'])),
      defaultInstallments: _int(valueAfter(['default installment'])),
      lastDepositDate: _date(valueAfter(['last deposit'])),
    );
  }

  static String _digits(String? s) =>
      s == null ? '' : s.replaceAll(RegExp(r'\D'), '');

  static int? _int(String? raw) {
    if (raw == null) return null;
    final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return d.isEmpty ? null : int.parse(d);
  }

  static int? _money(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'([\d,]+)(?:\.\d+)?').firstMatch(raw);
    if (m == null) return null;
    final whole = m.group(1)!.replaceAll(',', '');
    return whole.isEmpty ? null : int.parse(whole);
  }

  /// dd-MM-yyyy (the detail page format), plus dd/MM/yyyy and dd-MMM-yyyy.
  static DateTime? _date(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final s = raw.trim();
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final m1 = RegExp(r'^(\d{1,2})[-/ ]([A-Za-z]{3})[A-Za-z]*[-/ ](\d{4})')
        .firstMatch(s);
    if (m1 != null) {
      final mon = months[m1.group(2)!.toLowerCase()];
      if (mon != null) {
        return DateTime(int.parse(m1.group(3)!), mon, int.parse(m1.group(1)!));
      }
    }
    final m2 = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})').firstMatch(s);
    if (m2 != null) {
      return DateTime(int.parse(m2.group(3)!), int.parse(m2.group(2)!),
          int.parse(m2.group(1)!));
    }
    return null;
  }
}
