import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../calc/po_calc.dart';

enum Fortnight { first, second }

enum CollectionStatus { pending, deposited }

/// One Recurring Deposit account on the agent's list.
///
/// Core fields come from the "Agent Inquire and Update" list (Account No, Name,
/// Denomination, Month Paid Upto, Next Due Date, serial). The optional detail
/// fields (opening date, exact total deposit, pending/default installments,
/// last deposit) come from the per-account detail page via Deep Sync.
class RdAccount {
  final String accountNumber;
  final String customerName;
  final int denominationAmount;
  final DateTime nextDueDate;
  final int monthsPaid;
  final int serial;
  final CollectionStatus status;

  // --- Detail fields (Deep Sync; null until fetched) ---
  final DateTime? openingDate;
  final int? totalDeposit; // exact, from detail page
  final int? pendingInstallments;
  final int? defaultInstallments;
  final DateTime? lastDepositDate;

  const RdAccount({
    required this.accountNumber,
    required this.customerName,
    required this.denominationAmount,
    required this.nextDueDate,
    required this.monthsPaid,
    this.serial = 0,
    this.status = CollectionStatus.pending,
    this.openingDate,
    this.totalDeposit,
    this.pendingInstallments,
    this.defaultInstallments,
    this.lastDepositDate,
  });

  /// First fortnight (due day 1-15) or second (16+).
  Fortnight get fortnight =>
      nextDueDate.day <= 15 ? Fortnight.first : Fortnight.second;

  int get amountDue => denominationAmount;

  /// Exact deposited if known, else estimate (denomination x months paid).
  int get depositedAmount => totalDeposit ?? denominationAmount * monthsPaid;
  bool get hasDetail => openingDate != null || totalDeposit != null;

  // --- Derived (no detail fetch needed) ------------------------------------
  // Everything below is computed from the list fields the way the reference app
  // does it, so a plain list sync fills the whole account view — no per-account
  // detail crawl (which is what made "Deep Sync" slow).

  /// RD tenure in months. Accounts run 5 years (60); those continued past that
  /// run to 10 years (120). We infer the term from months already paid.
  int get termMonths => monthsPaid > 60 ? 120 : 60;
  int get termYears => (termMonths / 12).round();

  /// Derived opening date. Installments are sequential from opening, so the next
  /// unpaid one (the monthsPaid+1-th) falls monthsPaid months after opening —
  /// hence opening = nextDue − monthsPaid months. Exact even for defaulters.
  DateTime get derivedOpeningDate => _minusMonths(nextDueDate, monthsPaid);

  /// The opening date to show: the exact one if a detail fetch ever stored it,
  /// otherwise the derived one.
  DateTime get effectiveOpeningDate => openingDate ?? derivedOpeningDate;

  /// Installments still to run before maturity.
  int get installmentsToMaturity =>
      (termMonths - monthsPaid).clamp(0, termMonths);

  /// Date of the last deposit, exactly as the portal reports it.
  ///
  /// Deliberately NOT derived. It was previously guessed as `nextDue − 1 month`
  /// (the last installment's due period), which is wrong whenever a customer
  /// pays late, early, or several installments at once. The real transaction
  /// date only exists on the account's detail page, so this stays null until a
  /// detail fetch has run and the UI shows "—".
  DateTime? get effectiveLastDeposit => lastDepositDate;

  /// True once the exact portal figures have been pulled for this account.
  bool get hasExactDetail => lastDepositDate != null || totalDeposit != null;

  /// Total principal paid in over the full term (the "Paid Amount" figure).
  int get fullTermAmount => denominationAmount * termMonths;

  /// Interest rate locked at this account's opening (see [PoCalc.rdRateOn]) —
  /// NOT the current rate, so maturity is projected correctly for old accounts.
  double get annualRate => PoCalc.rdRateOn(effectiveOpeningDate);

  /// Projected India Post RD maturity value (quarterly compounding):
  ///   M = R · ((1+i)^n − 1) / (1 − (1+i)^(−1/3)),  i = rate/400, n = quarters.
  int get maturityAmount {
    final i = annualRate / 400.0;
    final n = termMonths / 3.0;
    final numerator = math.pow(1 + i, n) - 1;
    final denominator = 1 - math.pow(1 + i, -1 / 3);
    if (denominator == 0) return fullTermAmount;
    return (denominationAmount * numerator / denominator).round();
  }

  static DateTime _minusMonths(DateTime d, int months) {
    final total = d.year * 12 + (d.month - 1) - months;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final lastDay = DateTime(y, m + 1, 0).day; // clamp e.g. 31 -> 28/30
    return DateTime(y, m, d.day > lastDay ? lastDay : d.day);
  }

  String get dueDateLabel => DateFormat('dd-MMM-yyyy').format(nextDueDate);
  String get dueDateIso => DateFormat('yyyy-MM-dd').format(nextDueDate);
  String get openingDateIso =>
      DateFormat('yyyy-MM-dd').format(effectiveOpeningDate);
  String get lastDepositIso => effectiveLastDeposit == null
      ? '—'
      : DateFormat('yyyy-MM-dd').format(effectiveLastDeposit!);
  String get openingDateLabel =>
      DateFormat('dd-MMM-yyyy').format(effectiveOpeningDate);

  RdAccount copyWith({
    CollectionStatus? status,
    int? serial,
    DateTime? openingDate,
    int? totalDeposit,
    int? pendingInstallments,
    int? defaultInstallments,
    DateTime? lastDepositDate,
  }) =>
      RdAccount(
        accountNumber: accountNumber,
        customerName: customerName,
        denominationAmount: denominationAmount,
        nextDueDate: nextDueDate,
        monthsPaid: monthsPaid,
        serial: serial ?? this.serial,
        status: status ?? this.status,
        openingDate: openingDate ?? this.openingDate,
        totalDeposit: totalDeposit ?? this.totalDeposit,
        pendingInstallments: pendingInstallments ?? this.pendingInstallments,
        defaultInstallments: defaultInstallments ?? this.defaultInstallments,
        lastDepositDate: lastDepositDate ?? this.lastDepositDate,
      );

  Map<String, Object?> toMap() => {
        'account_number': accountNumber,
        'customer_name': customerName,
        'denomination_amount': denominationAmount,
        'next_due_date': nextDueDate.toIso8601String(),
        'months_paid': monthsPaid,
        'serial': serial,
        'status': status.name,
        'opening_date': openingDate?.toIso8601String(),
        'total_deposit': totalDeposit,
        'pending_installments': pendingInstallments,
        'default_installments': defaultInstallments,
        'last_deposit_date': lastDepositDate?.toIso8601String(),
      };

  factory RdAccount.fromMap(Map<String, Object?> m) => RdAccount(
        accountNumber: m['account_number'] as String,
        customerName: m['customer_name'] as String,
        denominationAmount: (m['denomination_amount'] as num).toInt(),
        nextDueDate: DateTime.parse(m['next_due_date'] as String),
        monthsPaid: (m['months_paid'] as num?)?.toInt() ?? 0,
        serial: (m['serial'] as num?)?.toInt() ?? 0,
        status:
            CollectionStatus.values.byName(m['status'] as String? ?? 'pending'),
        openingDate: _dt(m['opening_date']),
        totalDeposit: (m['total_deposit'] as num?)?.toInt(),
        pendingInstallments: (m['pending_installments'] as num?)?.toInt(),
        defaultInstallments: (m['default_installments'] as num?)?.toInt(),
        lastDepositDate: _dt(m['last_deposit_date']),
      );

  static DateTime? _dt(Object? v) =>
      v == null ? null : DateTime.tryParse(v as String);
}
