import 'collection.dart';
import 'daily_rule.dart';
import 'lot_packing.dart';
import 'rd_account.dart';
import 'summaries.dart';

/// How the collect sheet is ordered.
enum RoundSort {
  /// The order he actually walks his round, arranged by hand. Accounts he
  /// hasn't placed yet fall to the end, in due-date order.
  route,

  /// Soonest due first — the default until a route exists.
  due,

  /// Biggest installment first.
  amount,

  /// A–Z, for finding one person by name.
  name,
}

extension RoundSortLabel on RoundSort {
  String get label => switch (this) {
        RoundSort.route => 'My route',
        RoundSort.due => 'Due date',
        RoundSort.amount => 'Amount',
        RoundSort.name => 'Name',
      };
}

/// Which customers the collect sheet is showing.
enum RoundFilter {
  /// Everyone in the book — the default, so nothing ever looks missing.
  all,

  /// Still owes something this cycle: untouched, or part-paid.
  toCollect,

  /// Paid in full for this cycle, however they got there — one lump, thirty
  /// daily slices, or already on a list.
  paid,
}

extension RoundFilterLabel on RoundFilter {
  String get label => switch (this) {
        RoundFilter.all => 'All',
        RoundFilter.toCollect => 'To collect',
        RoundFilter.paid => 'Paid',
      };

  /// True when [entry] belongs in this filter.
  bool matches(RoundEntry entry) => switch (this) {
        RoundFilter.all => true,
        RoundFilter.toCollect => entry.group == RoundGroup.toCollect ||
            entry.group == RoundGroup.partial,
        // "Paid" means the month is covered — a part-paid daily customer is
        // NOT paid, however many visits they've made.
        RoundFilter.paid => entry.progress.complete ||
            entry.group == RoundGroup.settled,
      };
}

/// Where a customer stands in the current cycle. Order matters: the sheet shows
/// the groups top to bottom in this sequence.
enum RoundGroup {
  /// Nothing taken yet this cycle — the work still to do.
  toCollect,

  /// Part-paid: a daily customer mid-month, or someone short. Chased first as
  /// list day approaches.
  partial,

  /// Full installment in hand.
  collected,

  /// Nothing outstanding: already on a list this cycle, or the portal says
  /// they're paid ahead. Still shown and still collectible — the agent decides,
  /// and money taken beyond the month counts as an advance on the next one. The
  /// group only sorts them last and marks them, it never blocks him.
  settled,
}

/// One row of the collect sheet: a customer, their progress this cycle, and
/// which group they belong to.
class RoundEntry {
  const RoundEntry({required this.progress, required this.group});

  final CollectionProgress progress;
  final RoundGroup group;

  RdAccount get account => progress.account;
  String get accountNumber => account.accountNumber;
}

/// Builds the collect sheet: pure, no DB and no `DateTime.now()`, so the whole
/// round can be unit-tested the way [LotPacking] is.
class CollectionRound {
  /// Per-customer progress for [cycleYm], from that cycle's ledger rows.
  static Map<String, CollectionProgress> progressByAccount(
    List<RdAccount> accounts,
    List<Collection> cycleEntries, {
    DailyRule rule = DailyRule.standard,
  }) {
    final byAccount = <String, List<Collection>>{};
    for (final c in cycleEntries) {
      (byAccount[c.accountNumber] ??= []).add(c);
    }
    return {
      for (final a in accounts)
        a.accountNumber:
            _progressFor(a, byAccount[a.accountNumber] ?? const [], rule)
    };
  }

  static CollectionProgress _progressFor(
      RdAccount a, List<Collection> entries, DailyRule rule) {
    var amount = 0;
    var installments = 0;
    for (final e in entries) {
      amount += e.amount;
      installments += e.installments;
    }
    final sorted = [...entries]
      ..sort((x, y) => y.collectedAt.compareTo(x.collectedAt));
    return CollectionProgress(
      account: a,
      collected: amount,
      installments: installments,
      entries: sorted,
      dailyAmount: rule.amountFor(a),
    );
  }

  /// The full sheet for [now]'s cycle, sorted by [sort] and grouped.
  ///
  /// [alreadyListed] comes from [LotPacking.listedThisCycle] — cash that is
  /// already on a list must never be collected a second time.
  static List<RoundEntry> build(
    List<RdAccount> accounts,
    List<Collection> cycleEntries,
    DateTime now, {
    RoundSort sort = RoundSort.due,
    Set<String> alreadyListed = const <String>{},
    DailyRule rule = DailyRule.standard,
  }) {
    final progress = progressByAccount(accounts, cycleEntries, rule: rule);
    final rows = <RoundEntry>[];
    for (final a in accounts) {
      final p = progress[a.accountNumber]!;
      rows.add(RoundEntry(
        progress: p,
        group: groupFor(a, p, now, alreadyListed.contains(a.accountNumber)),
      ));
    }
    rows.sort((x, y) {
      final byGroup = x.group.index.compareTo(y.group.index);
      if (byGroup != 0) return byGroup;
      return compareWithin(x.account, y.account, sort, now);
    });
    return rows;
  }

  /// How many installments this customer should go down for on a list.
  ///
  /// This is the single decision that got auto-build deleted the first time.
  /// The old packer read the portal's next-due date and nothing else, so a
  /// customer who had handed three months' cash across at his door on Tuesday
  /// was written onto Thursday's list for one — and the agent discovered the
  /// shortfall at the counter, holding cash the list did not account for.
  ///
  /// The field ledger is the answer to that, because it is the only record of
  /// what was actually taken:
  ///
  ///   * **Cash in hand wins.** If this cycle's ledger holds whole months for
  ///     this customer ([CollectionProgress.advanceMonths]), that is the number,
  ///     whatever the portal thinks he owes. Three months collected is three
  ///     months listed; one month collected from a customer five months behind
  ///     is one month listed, because one month is what the agent is carrying.
  ///   * **Silence falls back to what is owed** — months behind, floored at
  ///     one. A customer the ledger has never seen this cycle tells us nothing,
  ///     and an agent who does not work the collect sheet has an empty ledger
  ///     for everyone; for both, the portal's arrears are the best guess
  ///     available.
  ///
  /// A part-month is deliberately not rounded up, and this is why the ledger
  /// having *seen* the customer matters more than what it says. A daily payer
  /// who is ₹600 into a ₹1,000 installment has not completed a month, so he
  /// seeds at **zero** — listing him for one would file a deposit against ₹400
  /// still in his pocket. Zero is a real answer here, which is exactly why the
  /// fallback is gated on `collected > 0` rather than on the seed: a floored
  /// zero must not be mistaken for silence and quietly promoted back to one.
  /// The auto screen leaves a zero-seed customer out of the default selection
  /// but still shows him, so the agent can add him if he knows better.
  ///
  /// Pure and deterministic: [now] is passed in, nothing is read from a clock
  /// or a database.
  static int listInstallments(
      RdAccount a, CollectionProgress? p, DateTime now) {
    // The ledger only gets to speak for customers it has actually seen. A
    // `collected` of zero is silence, not a statement that nothing is owed.
    if (p != null && p.collected > 0) return p.advanceMonths;
    final behind = AccountFilter.monthsBehind(a, now);
    return behind < 1 ? 1 : behind;
  }

  /// Which group a customer belongs to right now. Public so the sheet can
  /// re-grade one row after a collection without rebuilding (and re-sorting)
  /// the whole round under the agent's thumb.
  static RoundGroup groupFor(
      RdAccount a, CollectionProgress p, DateTime now, bool listed) {
    // Paid ahead on the portal, or the money is already on a list — nothing is
    // outstanding, so these sort to the bottom. They are still collectible.
    if (listed || AccountFilter.monthsBehind(a, now) < 0) {
      return RoundGroup.settled;
    }
    if (p.complete) return RoundGroup.collected;
    if (p.partial) return RoundGroup.partial;
    return RoundGroup.toCollect;
  }

  /// Ordering inside a group.
  static int compareWithin(
      RdAccount a, RdAccount b, RoundSort sort, DateTime now) {
    switch (sort) {
      case RoundSort.route:
        // Unplaced customers sit after the arranged round rather than jumbling
        // into the middle of it.
        final ra = a.routeOrder, rb = b.routeOrder;
        if (ra != null && rb != null && ra != rb) return ra.compareTo(rb);
        if (ra != null && rb == null) return -1;
        if (ra == null && rb != null) return 1;
        return a.nextDueDate.compareTo(b.nextDueDate);
      case RoundSort.due:
        final byDue = a.nextDueDate.compareTo(b.nextDueDate);
        return byDue != 0 ? byDue : a.customerName.compareTo(b.customerName);
      case RoundSort.amount:
        final byAmt = b.denominationAmount.compareTo(a.denominationAmount);
        return byAmt != 0 ? byAmt : a.customerName.compareTo(b.customerName);
      case RoundSort.name:
        return a.customerName
            .toLowerCase()
            .compareTo(b.customerName.toLowerCase());
    }
  }

  /// Total rupees taken across [entries] — the bag figure.
  static int total(List<Collection> entries) =>
      entries.fold(0, (sum, c) => sum + c.amount);

  /// Customers who have started paying but won't finish on their own — the
  /// group to chase before list day. Only meaningful late in the cycle, so the
  /// sheet asks for it from [warnFromDay] onward.
  static List<RoundEntry> shortfall(List<RoundEntry> rows) => rows
      .where((r) => r.group == RoundGroup.partial)
      .toList()
    ..sort((x, y) => y.progress.remaining.compareTo(x.progress.remaining));

  /// Day of the month from which the "short this month" warning appears. Late
  /// enough that a daily payer mid-month isn't flagged as a problem, early
  /// enough that he can still do something about it.
  static const int warnFromDay = 24;

  static bool nearCycleEnd(DateTime now) => now.day >= warnFromDay;

  /// Rupees still to collect across every customer who owes this cycle.
  static int outstanding(List<RoundEntry> rows) => rows
      .where((r) =>
          r.group == RoundGroup.toCollect || r.group == RoundGroup.partial)
      .fold(0, (sum, r) => sum + r.progress.remaining);
}
