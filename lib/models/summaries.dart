import 'rd_account.dart';

/// A count + amount pair shown in a dashboard stat box.
class Stat {
  final int count;
  final int amount;
  const Stat(this.count, this.amount);

  Stat add(int amount) => Stat(count + 1, this.amount + amount);
  static const zero = Stat(0, 0);
}

/// The cross-cutting buckets the collection dashboard shows. Each knows its own
/// title, how to test an account, and how to price it — so the Home summary
/// cards and the "View" list screen share one definition.
///
/// Bucket rules are month-granular and approximate where the list screen lacks
/// data (exact maturity date, precise arrears); refined once the per-account
/// detail fetch lands.
enum AccountFilter {
  all,
  firstHalfPending,
  firstHalfDeposited,
  secondHalfPending,
  secondHalfDeposited,
  defaulters,
  aboutToFreeze,
  maturity,
  advancedPaid,
  newAccounts;

  String get title => switch (this) {
        all => 'All Accounts',
        firstHalfPending => 'First Half · Pending',
        firstHalfDeposited => 'First Half · Deposited',
        secondHalfPending => 'Second Half · Pending',
        secondHalfDeposited => 'Second Half · Deposited',
        defaulters => 'Defaulters',
        aboutToFreeze => 'About to Freeze',
        maturity => 'Maturity',
        advancedPaid => 'Advanced Paid',
        newAccounts => 'New Accounts',
      };

  /// How many whole months the account is behind (>=1 = missed), 0 if due this
  /// month, negative if paid ahead into a future month.
  static int monthsBehind(RdAccount a, DateTime now) =>
      (now.year * 12 + now.month) -
      (a.nextDueDate.year * 12 + a.nextDueDate.month);

  bool test(RdAccount a, DateTime now) {
    final behind = monthsBehind(a, now);
    // Pending/Deposited/Defaulter are derived from the portal Next Due Date
    // (matches the core app), not local collection marking:
    //   behind == 0  -> due this month  -> Pending
    //   behind <= -1 -> due a future month (installment already paid) -> Deposited
    //   behind >= 1  -> overdue previous month(s) -> Defaulter
    final first = a.fortnight == Fortnight.first;
    final second = a.fortnight == Fortnight.second;
    return switch (this) {
      all => true,
      firstHalfPending => first && behind == 0,
      firstHalfDeposited => first && behind <= -1,
      secondHalfPending => second && behind == 0,
      secondHalfDeposited => second && behind <= -1,
      defaulters => behind >= 1,
      aboutToFreeze => behind >= 6,
      // Maturity/New now use derived fields (opening date, term-to-maturity)
      // computed from the list — so they fill on a plain sync, no detail crawl.
      maturity => a.pendingInstallments != null
          ? a.pendingInstallments! <= 2
          : (a.monthsPaid > 0 && a.installmentsToMaturity <= 2),
      advancedPaid => behind <= -2,
      newAccounts => !a.effectiveOpeningDate
          .isBefore(DateTime(now.year, now.month - 3, now.day)),
    };
  }

  /// Amount attributed to the account in this bucket. Arrears buckets price the
  /// full outstanding (denomination x months behind); others price one
  /// installment.
  int amountOf(RdAccount a, DateTime now) {
    if (this == defaulters || this == aboutToFreeze) {
      final behind = monthsBehind(a, now);
      return a.denominationAmount * (behind < 1 ? 1 : behind);
    }
    return a.denominationAmount;
  }

  Stat statOf(List<RdAccount> accounts, DateTime now) {
    var s = Stat.zero;
    for (final a in accounts) {
      if (test(a, now)) s = s.add(amountOf(a, now));
    }
    return s;
  }

  List<RdAccount> filter(List<RdAccount> accounts, DateTime now) =>
      accounts.where((a) => test(a, now)).toList();
}
