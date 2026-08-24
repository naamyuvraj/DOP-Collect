import 'lot.dart';
import 'rd_account.dart';
import 'summaries.dart';

/// The rules a collection list obeys — its size, its order, and which accounts
/// are already spoken for.
///
/// This used to BUILD lists too: one tap packed the whole book into as many
/// ₹20,000 lots as it took. That is gone. Auto-build decided, on the agent's
/// behalf and out of sight, which customers went on which list — and it decided
/// it from the portal's next-due dates alone, so it could not know that a
/// customer had already handed over three months' cash at the door and put him
/// down for one installment anyway. A list is a document he signs for at the
/// counter; he now assembles every one of them by hand in the list builder,
/// which is the only place that ever showed him what he was committing to.
///
/// What remains is the part the manual builder and the collect sheet still
/// need: the portal's limits, the priority order the builder offers as a
/// default sort, and [listedThisCycle].
///
/// Deliberately knows NOTHING about the field collection ledger. A list is a
/// portal document — the accounts he intends to deposit against, in the order
/// the counter wants them. Collections are purely his own field record.
///
/// Kept pure (no DB, no `DateTime.now()`) so it's unit-testable and
/// deterministic — the screen passes in `now`.
class LotPacking {
  /// Does this list still lay claim to its accounts?
  ///
  /// It used to be `lot.createdAt` in the current calendar month, full stop. Two
  /// ways that went wrong at a month boundary:
  ///
  ///   * A list built on 1 August to settle JULY marked its accounts as "listed
  ///     in August", so August's own collection silently skipped those
  ///     customers — missing from his lists with no explanation.
  ///   * A list built on 31 July and still UNSUBMITTED on 1 August stopped
  ///     blocking, so auto-build happily listed those accounts a second time
  ///     while the first list was still sitting there waiting to be submitted.
  ///
  /// The second is the one that duplicates work, so it decides the rule:
  ///
  ///   * NOT submitted -> always blocks, however old. The cash has not been
  ///     handed in yet; that list is a claim on those accounts until it is.
  ///   * Submitted -> blocks for the month it was actually FILED in
  ///     (submittedAt, falling back to createdAt). Beyond that the portal has
  ///     moved each account's due date forward, and the customer genuinely
  ///     owes again.
  static bool _stillBlocks(Lot lot, DateTime now) {
    if (!lot.isSubmitted) return true;
    final filed = lot.filedAt;
    return filed.year == now.year && filed.month == now.month;
  }

  /// Account numbers already sitting on a list built for [now]'s cycle — the
  /// replacement for the old sticky "deposited" mark. Between building a list
  /// and the next portal sync the account still *looks* due (its next-due date
  /// hasn't moved yet), so the collect sheet uses this to show that customer as
  /// settled rather than as still owing. A list from a previous month is
  /// ignored: that money is a closed cycle and the customer owes again.
  static Set<String> listedThisCycle(List<Lot> lots, DateTime now) => {
        for (final lot in lots)
          if (_stillBlocks(lot, now))
            for (final item in lot.items) item.accountNumber,
      };

  /// The list builder's default sort — the accounts you'd bank first at month
  /// end:
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
  ///
  /// Nine. The portal shows a saved list on one page of ten rows and uses one
  /// for the total, so a tenth account spills onto a second page. Auto-build
  /// and the manual builder must agree on this — if packing produced tens, the
  /// builder would refuse the lists its own auto-fill had just made.
  static const int maxAccountsPerList = 9;

  /// Postal rule: the rupee ceiling on one list.
  static const int defaultCap = 20000;
}
