import 'lot.dart';
import 'rd_account.dart';
import 'summaries.dart';

/// The rules a collection list obeys — its size, its order, how a pool of
/// accounts divides into lists, and which accounts are already spoken for.
///
/// Packing was once removed from here entirely. The auto-build it served chose,
/// on the agent's behalf and out of sight, which customers went on which list —
/// and it sized every row from the portal's next-due date alone, so a customer
/// who had already handed three months' cash over at the door still went down
/// for a single installment. The list was wrong, and it was wrong on a document
/// the agent signs for at the counter.
///
/// [pack] brings the arithmetic back without bringing that back. Two things
/// changed, and both are the reason it is safe now:
///
///   * It packs a pool the agent has already chosen and priced. It does not
///     decide WHO is on a list or how much they owe; it decides only how the
///     chosen rows divide into ₹20,000 lots. The field ledger — what was
///     actually taken at the door — is what the auto screen seeds those
///     installment counts from, which is precisely what the old builder could
///     not see.
///   * Nothing it produces is saved until the agent has read every proposed
///     list, row by row, and accepted it. It is a proposal, not a filing.
///
/// What packing is good for is the part no human should be doing by hand:
/// dividing eighty accounts into the FEWEST lists that respect both ceilings,
/// so each list is as full as the rules allow and he makes fewer trips.
///
/// Alongside it sits the part the manual builder and the collect sheet need:
/// the portal's limits, the priority order the builder offers as a default
/// sort, and [listedThisCycle].
///
/// Still deliberately knows NOTHING about the field collection ledger itself. A
/// list is a portal document — the accounts he intends to deposit against, in
/// the order the counter wants them. Collections are his own field record, and
/// the auto screen is where the two are reconciled: it reads the ledger, prices
/// each row from it, and hands [pack] rows that are already correct.
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
  /// Fifteen. This was nine, on the belief that the portal shows a saved list
  /// on one page of ten rows and uses one for the total. The agent's own
  /// submitted report (E-Banking ref C343193788) has fifteen rows, all
  /// "Success" — so the portal takes fifteen and the nine was a guess.
  ///
  /// [pack] and the manual builder must agree on this: if packing produced
  /// more than the builder accepts, the builder would refuse the lists the
  /// packer had just proposed. Keep this equal to
  /// [ListBuilderScreen.maxAccounts].
  static const int maxAccountsPerList = 15;


  /// Divide a priced pool into the fewest lists that satisfy both ceilings.
  ///
  /// Two constraints, and a list has to satisfy both: at most
  /// [maxAccountsPerList] rows, and — for CASH only — at most [amountCap]
  /// rupees. Cheque lists carry no rupee limit, so pass a null [amountCap] and
  /// only the row count binds.
  ///
  /// The objective the agent actually cares about is "fewer trips to the
  /// counter", which is the same thing as fewest lists, which is in turn the
  /// same thing as the most accounts per list. That is bin packing, so this is
  /// **best-fit decreasing**: place the largest rows first, each into whichever
  /// open list it leaves with the LEAST slack, and open a new list only when it
  /// fits nowhere. Decreasing order is what stops a run of small rows from
  /// eating the space the ₹9,000 rows will need; best-fit rather than first-fit
  /// is what closes lists off tightly instead of leaving every one of them a
  /// little short.
  ///
  /// It is a heuristic, not an optimum — bin packing has no cheap optimum — but
  /// on a book of RD denominations it lands on the true minimum essentially
  /// always, and it is deterministic, which matters more: the same pool must
  /// propose the same lists every time it is packed, or the agent cannot check
  /// the proposal against the one he read a minute ago.
  ///
  /// A row whose own amount exceeds [amountCap] fits nowhere by construction
  /// (three months of a ₹10,000 installment is ₹30,000 and no arrangement
  /// helps). Those come back in [PackResult.unplaceable] rather than being
  /// dropped, because an account that disappears silently between the pool and
  /// the proposal is discovered at the counter.
  ///
  /// Rows inside a list come back in [priorityCompare] order — the same order
  /// the manual builder offers — and the lists themselves come back fullest
  /// first, so if the round is abandoned half-way the largest deposits are the
  /// ones already filed.
  static PackResult pack(
    List<PackItem> items,
    DateTime now, {
    int? amountCap = defaultCap,
    int maxAccounts = maxAccountsPerList,
  }) {
    final unplaceable = <PackItem>[];
    final placeable = <PackItem>[];
    for (final item in items) {
      if (item.installments <= 0) continue; // not actually on the list
      if (amountCap != null && item.amount > amountCap) {
        unplaceable.add(item);
      } else {
        placeable.add(item);
      }
    }

    // Descending by amount, then by priority, then by account number. The last
    // two are not cosmetic: two ₹2,000 rows must break their tie the same way
    // on every run or the proposal is not reproducible.
    placeable.sort((a, b) {
      final byAmount = b.amount.compareTo(a.amount);
      if (byAmount != 0) return byAmount;
      final byPriority = priorityCompare(a.account, b.account, now);
      if (byPriority != 0) return byPriority;
      return a.account.accountNumber.compareTo(b.account.accountNumber);
    });

    final bins = <PackedLot>[];
    for (final item in placeable) {
      PackedLot? best;
      var bestSlack = 0;
      for (final bin in bins) {
        if (bin.count >= maxAccounts) continue;
        if (amountCap == null) {
          // No rupee ceiling: every open list is equally good, so fill the
          // first one that still has a row free and keep lists contiguous.
          best = bin;
          break;
        }
        final slack = amountCap - (bin.total + item.amount);
        if (slack < 0) continue;
        if (best == null || slack < bestSlack) {
          best = bin;
          bestSlack = slack;
        }
      }
      if (best == null) {
        bins.add(PackedLot([item]));
      } else {
        best.items.add(item);
      }
    }

    for (final bin in bins) {
      bin.items.sort((a, b) {
        final byPriority = priorityCompare(a.account, b.account, now);
        if (byPriority != 0) return byPriority;
        return a.account.accountNumber.compareTo(b.account.accountNumber);
      });
    }
    bins.sort((a, b) {
      final byTotal = b.total.compareTo(a.total);
      if (byTotal != 0) return byTotal;
      return b.count.compareTo(a.count);
    });

    return PackResult(lots: bins, unplaceable: unplaceable);
  }

  /// Postal rule: the rupee ceiling on one list.
  static const int defaultCap = 20000;
}

/// One account, and how many installments it is down for, offered to the
/// packer.
///
/// The pair is atomic. An account is one printed row on one filed list, so the
/// packer may move it between lists but must never split its installments
/// across two — a customer's three months landing on two different references
/// is a reconciliation the agent has to do by hand at the counter.
class PackItem {
  const PackItem({required this.account, required this.installments});

  final RdAccount account;
  final int installments;

  int get amount => account.denominationAmount * installments;

  PackItem withInstallments(int n) =>
      PackItem(account: account, installments: n);
}

/// One list the packer proposes.
///
/// Not a [Lot]: nothing here has been saved, no account has been marked spoken
/// for, and the agent can still edit or discard it. It becomes a [Lot] only
/// when he accepts the proposal.
class PackedLot {
  PackedLot(this.items);

  final List<PackItem> items;

  int get count => items.length;
  int get total => items.fold(0, (s, i) => s + i.amount);
}

/// What [LotPacking.pack] made of the pool: the lists it could build, and the
/// rows it could not place on any of them.
class PackResult {
  const PackResult({required this.lots, required this.unplaceable});

  final List<PackedLot> lots;

  /// Rows whose own amount exceeds the cash ceiling on their own. Surfaced, not
  /// dropped — see [LotPacking.pack].
  final List<PackItem> unplaceable;

  bool get isEmpty => lots.isEmpty;
  int get lotCount => lots.length;
  int get accountCount => lots.fold(0, (s, l) => s + l.count);
  int get totalAmount => lots.fold(0, (s, l) => s + l.total);
}
