import 'rd_account.dart';

/// How much a customer hands over on one daily visit.
///
/// The default is the month's installment spread over the month — ₹15,000/30 =
/// ₹500, ₹3,000/30 = ₹100 — so it is right for every account without the agent
/// setting anything up. It rounds **up** to the rupee, because a daily amount
/// that rounds down can never reach the installment: ₹1,000/30 is ₹33.33, and
/// thirty visits of ₹33 leave the agent covering the shortfall himself.
///
/// He can still overrule it, at either level:
///   * the whole book — change the number of days, or put every account on one
///     flat amount ([DailyMode.flat]);
///   * one customer — [RdAccount.dailyAmount], set from the collect sheet.
///
/// A per-customer amount always wins over the book-wide rule.
enum DailyMode {
  /// Monthly installment ÷ [DailyRule.days].
  perMonth,

  /// The same rupee amount for every account, whatever it is worth.
  flat,
}

class DailyRule {
  const DailyRule({
    this.mode = DailyMode.perMonth,
    this.days = defaultDays,
    this.flatAmount = 0,
  });

  final DailyMode mode;

  /// Visits he expects to make in a month. 30 by default.
  final int days;

  /// The amount every account pays under [DailyMode.flat].
  final int flatAmount;

  static const int defaultDays = 30;
  static const DailyRule standard = DailyRule();

  /// The daily amount for [a] — the customer's own figure if he has set one,
  /// otherwise the book-wide rule.
  int amountFor(RdAccount a) {
    final own = a.dailyAmount;
    if (own != null && own > 0) return own;
    return baseFor(a);
  }

  /// The rule's amount for [a], ignoring any per-customer override. This is
  /// what the collect sheet offers as the starting suggestion.
  int baseFor(RdAccount a) {
    if (mode == DailyMode.flat) return flatAmount > 0 ? flatAmount : 1;
    final d = days <= 0 ? defaultDays : days;
    // Round UP: thirty visits must be able to reach the installment.
    final raw = (a.denominationAmount + d - 1) ~/ d;
    return raw < 1 ? 1 : raw;
  }
}
