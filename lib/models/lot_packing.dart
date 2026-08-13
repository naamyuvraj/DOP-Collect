import 'lot.dart';
import 'rd_account.dart';
import 'summaries.dart';

/// Auto list-making: turn the accounts that need collecting into a set of
/// ₹[cap]-capped lots ("queues"), most-unpaid first, in one go.
///
/// Deliberately knows NOTHING about the field collection ledger. A list is a
/// portal document — the accounts he intends to deposit against, in the order
/// the counter wants them — and he builds it himself, adding and removing
/// names before he submits. Tying it to who had already handed over cash meant
/// two independent systems could disagree about what belonged on a list, and
/// each answer was wrong in a different way. Collections are now purely his
/// own field record; lists are purely the portal's. Neither reads the other.
///
/// Kept pure (no DB, no `DateTime.now()`) so it's unit-testable and
/// deterministic — the screen passes in `now`.
class LotPacking {
  /// Accounts to collect this cycle: due this month or overdue (not paid
  /// ahead) and not already on a list for this cycle — sorted by
  /// [priorityCompare] (on-time-and-owing first, then overdue, then value).
  ///
  /// "Already collected" is deliberately NOT a stored flag. It used to be
  /// `status == deposited`, which nothing ever reset: an account collected in
  /// August stayed excluded in September, October and forever after, so
  /// auto-build silently shrank every month. Both halves are now derived —
  /// paid-ahead comes from the portal's own next-due date, and the
  /// don't-list-twice guard comes from [alreadyListed] (see [listedThisCycle]),
  /// which expires on its own when the cycle turns over.
  static List<RdAccount> eligible(
    List<RdAccount> accounts,
    DateTime now, {
    Set<String> alreadyListed = const <String>{},
  }) {
    final out = accounts
        .where((a) =>
            !alreadyListed.contains(a.accountNumber) &&
            AccountFilter.monthsBehind(a, now) >= 0)
        .toList();
    out.sort((a, b) => priorityCompare(a, b, now));
    return out;
  }

  /// Account numbers already sitting on a list built for [now]'s cycle — the
  /// replacement for the old sticky "deposited" mark. Between building a list
  /// and the next portal sync the account still *looks* due (its next-due date
  /// hasn't moved yet), so without this a re-run would pack it a second time.
  /// A list from a previous month is ignored: that money is a closed cycle and
  /// the customer owes again.
  static Set<String> listedThisCycle(List<Lot> lots, DateTime now) => {
        for (final lot in lots)
          if (lot.createdAt.year == now.year && lot.createdAt.month == now.month)
            for (final item in lot.items) item.accountNumber,
      };

  /// Order for building lists — the accounts you'd bank first at month end:
  /// **owed-and-on-time** (due this month, reliable), then **overdue** (still
  /// owes), then **most valuable** (highest installment) within a tier.
  /// Paid-ahead accounts sort LAST — they don't owe anything this cycle, so
  /// they must never top a "make a list to collect" screen.
  ///
  /// Everything here comes from the portal's own next-due date. The field
  /// ledger is not consulted: a list is a starting point he edits by hand, not
  /// a claim about which cash he is carrying.
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

  /// Postal rule: the rupee ceiling on one list.
  static const int defaultCap = 20000;

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
          {int cap = 20000,
          String mode = 'Cash',
          Set<String> alreadyListed = const <String>{}}) =>
      pack(eligible(accounts, now, alreadyListed: alreadyListed), now,
          cap: cap, mode: mode);
}
