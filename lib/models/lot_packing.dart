import 'lot.dart';
import 'rd_account.dart';
import 'summaries.dart';

/// Auto list-making: turn the accounts that need collecting into a set of
/// ₹[cap]-capped lots ("queues"), most-unpaid first, in one go.
///
/// Kept pure (no DB, no `DateTime.now()`) so it's unit-testable and
/// deterministic — the screen passes in `now`.
class LotPacking {
  /// Accounts to collect this cycle: due this month or overdue (not paid
  /// ahead) and not already marked collected — sorted by [priorityCompare]
  /// (on-time-and-owing first, then overdue, then value).
  static List<RdAccount> eligible(List<RdAccount> accounts, DateTime now) {
    final out = accounts
        .where((a) =>
            a.status != CollectionStatus.deposited &&
            AccountFilter.monthsBehind(a, now) >= 0)
        .toList();
    out.sort((a, b) => priorityCompare(a, b, now));
    return out;
  }

  /// Order for building lists — the accounts you'd bank first at month end:
  /// **owed-and-on-time first** (due this month, reliable), then **overdue**
  /// (still owes), then **most valuable** (highest installment) within a tier.
  /// Paid-ahead accounts sort LAST — they don't owe anything this cycle, so
  /// they must never top a "make a list to collect" screen.
  static int priorityCompare(RdAccount a, RdAccount b, DateTime now) {
    int tier(RdAccount x) {
      final behind = AccountFilter.monthsBehind(x, now);
      if (behind == 0) return 2; // due this month, on time — collect first
      if (behind >= 1) return 1; // overdue — still owes
      return 0; // paid ahead — doesn't owe this cycle, so last
    }

    final byTier = tier(b).compareTo(tier(a));
    if (byTier != 0) return byTier;
    final byValue = b.denominationAmount.compareTo(a.denominationAmount);
    if (byValue != 0) return byValue;
    return a.nextDueDate.compareTo(b.nextDueDate);
  }

  /// Portal rule: at most this many accounts per list, any mode.
  static const int maxAccountsPerList = 50;

  /// Greedily pack [accounts] (one installment each) into consecutive lots,
  /// preserving the caller's order (from [eligible] that's on-time-owing first).
  /// Each lot respects TWO
  /// portal limits:
  ///   - **≤ [maxAccountsPerList] accounts** (all modes), and
  ///   - **≤ [cap] amount for CASH only** — cheque modes have no amount cap.
  /// Returns unsaved [Lot]s.
  static List<Lot> pack(
    List<RdAccount> accounts,
    DateTime now, {
    int cap = 20000,
    String mode = 'Cash',
  }) {
    // Cash caps the rupee total; DOP / Non-DOP cheque do not.
    final capsAmount = !mode.toLowerCase().contains('cheque');
    final lots = <Lot>[];
    var current = <LotItem>[];
    var running = 0;

    void flush() {
      if (current.isNotEmpty) {
        lots.add(Lot(createdAt: now, mode: mode, items: current));
        current = <LotItem>[];
        running = 0;
      }
    }

    for (final a in accounts) {
      final amt = a.denominationAmount;
      // Start a new lot when adding this account would break a limit — the
      // 50-account cap (any mode) or the amount cap (cash only). A lone account
      // over the amount cap still gets its own lot rather than being dropped.
      final overAmount = capsAmount && running + amt > cap;
      final overCount = current.length >= maxAccountsPerList;
      if (current.isNotEmpty && (overAmount || overCount)) flush();
      current.add(LotItem(
        accountNumber: a.accountNumber,
        customerName: a.customerName,
        denomination: a.denominationAmount,
        installments: 1,
      ));
      running += amt;
    }
    flush();
    return lots;
  }

  /// Convenience: eligible + pack in one call.
  static List<Lot> build(List<RdAccount> accounts, DateTime now,
          {int cap = 20000, String mode = 'Cash'}) =>
      pack(eligible(accounts, now), now, cap: cap, mode: mode);
}
