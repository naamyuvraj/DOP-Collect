import 'package:intl/intl.dart';

import 'rd_account.dart';

/// One handover of cash, from a customer to the agent, at a point in time.
///
/// Deliberately an event, not a state. The app's older "collected" mark was a
/// boolean on the account that nothing ever cleared, so a customer collected in
/// August stayed marked forever and auto-build quietly skipped them in every
/// later month. Rows here carry the cycle they belong to, so "collected this
/// month" is a SUM that stops counting on its own when the month turns over.
class Collection {
  const Collection({
    this.id,
    required this.accountNumber,
    required this.amount,
    required this.collectedAt,
    required this.cycleYm,
    this.installments = 1,
    this.note,
  });

  final int? id;
  final String accountNumber;

  /// Rupees actually taken. A monthly customer's whole installment, or one
  /// day's small change from a daily one.
  final int amount;

  final DateTime collectedAt;

  /// The collection cycle this belongs to, `yyyy-MM`. Stamped at collection
  /// time rather than derived later, so a payment taken on the 31st for the
  /// month just ending can't drift into the next one.
  final String cycleYm;

  /// Months of RD this hands over — 1 normally, more when a customer pays
  /// ahead. Summed per cycle and carried onto the list.
  final int installments;

  final String? note;

  /// `yyyy-MM` key for [when] — the cycle a collection made then belongs to.
  static String cycleOf(DateTime when) => DateFormat('yyyy-MM').format(when);

  String get timeLabel => DateFormat('h:mm a').format(collectedAt);
  String get dayLabel => DateFormat('dd-MMM-yyyy').format(collectedAt);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'account_number': accountNumber,
        'amount': amount,
        'installments': installments,
        'collected_at': collectedAt.toIso8601String(),
        'cycle_ym': cycleYm,
        'note': note,
      };

  static Collection fromMap(Map<String, Object?> m) => Collection(
        id: (m['id'] as num?)?.toInt(),
        accountNumber: m['account_number'] as String,
        amount: (m['amount'] as num).toInt(),
        installments: (m['installments'] as num?)?.toInt() ?? 1,
        collectedAt: DateTime.parse(m['collected_at'] as String),
        cycleYm: m['cycle_ym'] as String,
        note: m['note'] as String?,
      );

  Collection copyWith({int? id}) => Collection(
        id: id ?? this.id,
        accountNumber: accountNumber,
        amount: amount,
        collectedAt: collectedAt,
        cycleYm: cycleYm,
        installments: installments,
        note: note,
      );
}

/// What one customer owes and has handed over in a single cycle — the row model
/// behind the collect sheet.
///
/// Everything here is computed from the account plus that cycle's [Collection]
/// rows. Nothing is stored, so it cannot go stale.
class CollectionProgress {
  const CollectionProgress({
    required this.account,
    required this.collected,
    required this.installments,
    required this.entries,
    required this.dailyAmount,
  });

  final RdAccount account;

  /// This customer's per-visit amount, already resolved from the book-wide
  /// [DailyRule] and any override of their own. Passed in rather than computed
  /// here so the rule lives in one place.
  final int dailyAmount;

  /// Rupees taken from this customer this cycle.
  final int collected;

  /// Months handed over this cycle (an advance payer clears 2–3 at once).
  final int installments;

  /// This cycle's individual handovers, newest first — the per-customer log.
  final List<Collection> entries;

  /// One month's installment. The target a daily payer is working toward.
  int get target => account.denominationAmount;

  /// Still to collect this cycle. Never negative — an overpayment is an
  /// advance for next month, not a debt owed back.
  int get remaining => (target - collected).clamp(0, target);

  /// 0.0 – 1.0 for the row's progress bar.
  double get fraction => target <= 0 ? 0 : (collected / target).clamp(0.0, 1.0);

  bool get untouched => collected == 0;

  /// The full installment is in hand — this customer can go on a list.
  bool get complete => collected >= target;

  /// Started but not finished: the state a daily payer sits in most of the
  /// month, and the one that needs chasing before list day.
  bool get partial => collected > 0 && collected < target;

  /// Whole months paid ahead beyond this one, for the advance rebate.
  int get advanceMonths => target <= 0 ? 0 : (collected ~/ target);

  /// A full-installment swipe: whatever still closes this month, or a whole
  /// month again once this one is paid (an advance for the next).
  int get monthlyNext => remaining == 0 ? target : remaining;

  /// A daily swipe: this customer's per-visit amount — **except** once the
  /// remainder drops below it, when it becomes the remainder itself.
  ///
  /// That last rule is what makes daily collection reconcile. Rounding up means
  /// ₹1,000/30 = ₹34, and thirty of those would overshoot to ₹1,020; capping at
  /// the remainder stops the month at exactly ₹1,000 instead of taking money
  /// the customer doesn't owe.
  int get dailyNext {
    final daily = dailyAmount <= 0 ? 1 : dailyAmount;
    if (remaining == 0) return daily; // paying ahead into next month
    return daily < remaining ? daily : remaining;
  }

  /// True when [dailyNext] is closing out the cycle rather than taking another
  /// ordinary daily instalment — the sheet says "settle ₹360" instead of "₹34".
  bool get isSettling => remaining > 0 && remaining <= dailyAmount;
}
