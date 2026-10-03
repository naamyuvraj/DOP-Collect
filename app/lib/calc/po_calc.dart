import 'dart:math' as math;

import '../util/format.dart';

/// India Post savings schemes the calculator supports.
enum PoScheme {
  rd,
  td1,
  td2,
  td3,
  td5,
  mis,
  scss,
  nsc,
  kvp,
  mssc,
  ppf,
  ssa,
  sb,
  custom,
}

/// How the deposit is made — decides the amount label and the maths.
enum DepositMode { monthly, yearly, lumpSum }

/// One scheme's rules: current rate, default tenure and deposit style.
///
/// Rates are the official India Post rates **w.e.f 1-Jul-2026**. They are reset
/// quarterly, so [PoCalc.ratesEffective] is shown next to them in the UI and the
/// rate stays user-editable on every calculation.
class SchemeSpec {
  const SchemeSpec({
    required this.scheme,
    required this.code,
    required this.name,
    required this.rate,
    required this.mode,
    required this.years,
    this.tenureEditable = false,
    this.note,
  });

  final PoScheme scheme;
  final String code;
  final String name;
  final double rate;
  final DepositMode mode;
  final double years;
  final bool tenureEditable;
  final String? note;

  String get amountLabel => switch (mode) {
        DepositMode.monthly => 'Monthly Deposit',
        DepositMode.yearly => 'Yearly Deposit',
        DepositMode.lumpSum => 'Deposit Amount',
      };
}

/// Result of one calculation.
class CalcResult {
  const CalcResult({
    required this.deposited,
    required this.maturity,
    required this.interest,
    this.payout,
    this.rows = const [],
  });

  /// Total money put in.
  final double deposited;

  /// Amount received at maturity (for payout schemes this is the principal
  /// returned, with the income paid out along the way — see [payout]).
  final double maturity;

  /// Interest earned in total.
  final double interest;

  /// For MIS/SCSS/SB: the periodic income line, e.g. "Monthly income".
  final String? payout;

  /// Extra label/value lines for the result card.
  final List<(String, String)> rows;
}

/// Post Office interest maths. Pure + deterministic so it is unit-testable and
/// can back both the calculator screen and the AI assistant (the assistant
/// parses the question, this computes the number — never the LLM).
class PoCalc {
  static const String ratesEffective = '1-Jul-2026 to 30-Sep-2026';

  static const List<SchemeSpec> schemes = [
    SchemeSpec(
      scheme: PoScheme.rd,
      code: 'RD',
      name: 'Recurring Deposit',
      rate: 6.7,
      mode: DepositMode.monthly,
      years: 5,
      tenureEditable: true,
      note: 'Quarterly compounding. 5-year term, extendable to 10.',
    ),
    SchemeSpec(
      scheme: PoScheme.td1,
      code: '1TD',
      name: '1 Year Term Deposit',
      rate: 6.9,
      mode: DepositMode.lumpSum,
      years: 1,
    ),
    SchemeSpec(
      scheme: PoScheme.td2,
      code: '2TD',
      name: '2 Year Term Deposit',
      rate: 7.0,
      mode: DepositMode.lumpSum,
      years: 2,
    ),
    SchemeSpec(
      scheme: PoScheme.td3,
      code: '3TD',
      name: '3 Year Term Deposit',
      rate: 7.1,
      mode: DepositMode.lumpSum,
      years: 3,
    ),
    SchemeSpec(
      scheme: PoScheme.td5,
      code: '5TD',
      name: '5 Year Term Deposit',
      rate: 7.5,
      mode: DepositMode.lumpSum,
      years: 5,
    ),
    SchemeSpec(
      scheme: PoScheme.mis,
      code: 'MIS',
      name: 'Monthly Income Scheme',
      rate: 7.4,
      mode: DepositMode.lumpSum,
      years: 5,
      note: 'Interest paid monthly; deposit returned at maturity.',
    ),
    SchemeSpec(
      scheme: PoScheme.scss,
      code: 'SCSS',
      name: 'Senior Citizen Savings Scheme',
      rate: 8.2,
      mode: DepositMode.lumpSum,
      years: 5,
      note: 'Interest paid quarterly; deposit returned at maturity.',
    ),
    SchemeSpec(
      scheme: PoScheme.nsc,
      code: 'NSC',
      name: 'National Savings Certificate',
      rate: 7.7,
      mode: DepositMode.lumpSum,
      years: 5,
      note: 'Annual compounding, paid at maturity.',
    ),
    SchemeSpec(
      scheme: PoScheme.kvp,
      code: 'KVP',
      name: 'Kisan Vikas Patra',
      rate: 7.5,
      mode: DepositMode.lumpSum,
      years: 0, // derived: time to double
      note: 'Runs until the deposit doubles.',
    ),
    SchemeSpec(
      scheme: PoScheme.mssc,
      code: 'MSSC',
      name: 'Mahila Samman Savings Certificate',
      rate: 7.5,
      mode: DepositMode.lumpSum,
      years: 2,
      note: 'Quarterly compounding, 2-year term.',
    ),
    SchemeSpec(
      scheme: PoScheme.ppf,
      code: 'PPF',
      name: 'Public Provident Fund',
      rate: 7.1,
      mode: DepositMode.yearly,
      years: 15,
      tenureEditable: true,
      note: 'Annual compounding on yearly deposits.',
    ),
    SchemeSpec(
      scheme: PoScheme.ssa,
      code: 'SSA',
      name: 'Sukanya Samriddhi Account',
      rate: 8.2,
      mode: DepositMode.yearly,
      years: 21,
      note: 'Deposits for 15 years, matures at 21 years.',
    ),
    SchemeSpec(
      scheme: PoScheme.sb,
      code: 'SB',
      name: 'Post Office Savings Account',
      rate: 4.0,
      mode: DepositMode.lumpSum,
      years: 1,
      tenureEditable: true,
      note: 'Simple interest on the balance.',
    ),
    SchemeSpec(
      scheme: PoScheme.custom,
      code: 'Custom',
      name: 'Custom (compound)',
      rate: 7.0,
      mode: DepositMode.lumpSum,
      years: 5,
      tenureEditable: true,
      note: 'Annual compounding on any amount, rate and term.',
    ),
  ];

  static SchemeSpec spec(PoScheme s) =>
      schemes.firstWhere((e) => e.scheme == s);

  /// Built-in India Post 5-year RD rate history (yyyymm effective-from, rate),
  /// ascending. Used as the seed and offline fallback. RD locks its rate at
  /// opening for the whole term, so an EXISTING account's maturity is projected
  /// with the rate from when it was opened. Verified against a real account
  /// opened 02-Nov-2018 showing 7.3% (and 6.9% just before, per the agent).
  static const List<(int, double)> defaultRdRateHistory = [
    (201604, 7.4),
    (201610, 7.3),
    (201704, 7.2),
    (201707, 7.1),
    (201801, 6.9),
    (201810, 7.3),
    (201907, 7.2),
    (202004, 5.8), // held three years
    (202304, 6.2),
    (202307, 6.5),
    (202310, 6.7), // current
  ];

  /// The LIVE table (built-in seed, overridable by the user from Settings so a
  /// new quarter's rate can be added without a code update).
  static List<(int, double)> _rdRates = List.of(defaultRdRateHistory);

  static List<(int, double)> get rdRates => List.unmodifiable(_rdRates);

  /// Replace the live table (from stored user edits). Drops invalid rows and
  /// keeps it sorted; falls back to the built-in table if nothing valid remains.
  static void setRdRates(List<(int, double)> rows) {
    final clean = rows.where((r) => r.$1 >= 190001 && r.$2 > 0).toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    _rdRates = clean.isEmpty ? List.of(defaultRdRateHistory) : clean;
  }

  static void resetRdRates() => _rdRates = List.of(defaultRdRateHistory);

  static double rdRateOn(DateTime date) {
    final key = date.year * 100 + date.month;
    var rate = _rdRates.first.$2;
    for (final e in _rdRates) {
      if (key >= e.$1) {
        rate = e.$2;
      } else {
        break;
      }
    }
    return rate;
  }

  /// Current 5-year RD rate (latest table entry) — the calculator's default for
  /// a NEW deposit.
  static double get rdCurrentRate => _rdRates.last.$2;

  /// Look a scheme up by code/name fragment ('rd', 'mis', '5td', 'sukanya'…).
  static SchemeSpec? byName(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final s in schemes) {
      if (s.code.toLowerCase() == q) return s;
    }
    for (final s in schemes) {
      if (s.name.toLowerCase().contains(q) ||
          q.contains(s.code.toLowerCase())) {
        return s;
      }
    }
    const aliases = {
      'recurring': PoScheme.rd,
      'sukanya': PoScheme.ssa,
      'ssy': PoScheme.ssa,
      'senior': PoScheme.scss,
      'kisan': PoScheme.kvp,
      'mahila': PoScheme.mssc,
      'monthly income': PoScheme.mis,
      'term deposit': PoScheme.td5,
      'fd': PoScheme.td5,
      'savings': PoScheme.sb,
      'provident': PoScheme.ppf,
      'national savings': PoScheme.nsc,
    };
    for (final e in aliases.entries) {
      if (q.contains(e.key)) return spec(e.value);
    }
    return null;
  }

  /// Compute a scheme. [amount] is the monthly/yearly/lump deposit; [years] and
  /// [rate] override the scheme defaults when supplied.
  static CalcResult compute(
    PoScheme scheme, {
    required double amount,
    double? years,
    double? rate,
  }) {
    final s = spec(scheme);
    final r = rate ?? s.rate;
    final y = years ?? s.years;

    switch (scheme) {
      case PoScheme.rd:
        // India Post RD: quarterly compounding on monthly deposits.
        //   M = R · ((1+i)^n − 1) / (1 − (1+i)^(−1/3)),  i = r/400, n = quarters
        final i = r / 400.0;
        final n = y * 4;
        final maturity = i == 0
            ? amount * y * 12
            : amount *
                (math.pow(1 + i, n) - 1) /
                (1 - math.pow(1 + i, -1 / 3));
        final dep = amount * y * 12;
        return CalcResult(
          deposited: dep,
          maturity: maturity,
          interest: maturity - dep,
          rows: [('Installments', '${(y * 12).round()}')],
        );

      case PoScheme.td1:
      case PoScheme.td2:
      case PoScheme.td3:
      case PoScheme.td5:
      case PoScheme.mssc:
        // Quarterly compounding on a lump sum.
        final maturity = amount * math.pow(1 + r / 400.0, 4 * y);
        return CalcResult(
          deposited: amount,
          maturity: maturity.toDouble(),
          interest: maturity - amount,
        );

      case PoScheme.nsc:
      case PoScheme.custom:
        // Annual compounding on a lump sum.
        final maturity = amount * math.pow(1 + r / 100.0, y);
        return CalcResult(
          deposited: amount,
          maturity: maturity.toDouble(),
          interest: maturity - amount,
        );

      case PoScheme.kvp:
        // Runs until the money doubles: t = ln2 / ln(1 + r/100).
        final t = r <= 0 ? 0.0 : math.log(2) / math.log(1 + r / 100.0);
        final months = (t * 12).round();
        return CalcResult(
          deposited: amount,
          maturity: amount * 2,
          interest: amount,
          rows: [
            ('Doubles in', '${months ~/ 12} yr ${months % 12} mo'),
          ],
        );

      case PoScheme.mis:
        // Monthly income; principal returned at maturity.
        final monthly = amount * r / 1200.0;
        return CalcResult(
          deposited: amount,
          maturity: amount,
          interest: monthly * 12 * y,
          payout: 'Monthly income',
          rows: [
            ('Monthly income', inr(monthly.round())),
            ('Over $y years', inr((monthly * 12 * y).round())),
          ],
        );

      case PoScheme.scss:
        // Quarterly income; principal returned at maturity.
        final quarterly = amount * r / 400.0;
        return CalcResult(
          deposited: amount,
          maturity: amount,
          interest: quarterly * 4 * y,
          payout: 'Quarterly income',
          rows: [
            ('Quarterly income', inr(quarterly.round())),
            ('Over $y years', inr((quarterly * 4 * y).round())),
          ],
        );

      case PoScheme.sb:
        // Simple interest on the balance.
        final interest = amount * r / 100.0 * y;
        return CalcResult(
          deposited: amount,
          maturity: amount + interest,
          interest: interest,
        );

      case PoScheme.ppf:
        // Yearly deposits, annual compounding (annuity-due).
        final maturity = _annuityDue(amount, r, y);
        final dep = amount * y;
        return CalcResult(
          deposited: dep,
          maturity: maturity,
          interest: maturity - dep,
        );

      case PoScheme.ssa:
        // Deposits for 15 years, then grows untouched until year 21.
        const depositYears = 15.0;
        final atYear15 = _annuityDue(amount, r, depositYears);
        final grown =
            atYear15 * math.pow(1 + r / 100.0, (y - depositYears).clamp(0, 99));
        final dep = amount * depositYears;
        return CalcResult(
          deposited: dep,
          maturity: grown.toDouble(),
          interest: grown - dep,
          rows: [
            ('Deposits', '15 years'),
            ('Matures', '${y.round()} years'),
          ],
        );
    }
  }

  /// Future value of [n] yearly deposits made at the start of each year.
  static double _annuityDue(double a, double r, double n) {
    final i = r / 100.0;
    if (i == 0) return a * n;
    return a * ((math.pow(1 + i, n) - 1) / i) * (1 + i);
  }

  /// RD rebate for paying installments in advance (agent-relevant).
  /// India Post pays ₹10 per ₹100 denomination for 12 advance installments and
  /// ₹4 per ₹100 for 6 — pro-rated here by denomination.
  static double rdRebate({required double denomination, required int advance}) {
    if (advance >= 12) return denomination / 100.0 * 10.0;
    if (advance >= 6) return denomination / 100.0 * 4.0;
    return 0;
  }
}
