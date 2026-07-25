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
  /// ahead) and not already marked collected — sorted most-unpaid first.
  static List<RdAccount> eligible(List<RdAccount> accounts, DateTime now) {
    final out = accounts
        .where((a) =>
            a.status != CollectionStatus.deposited &&
            AccountFilter.monthsBehind(a, now) >= 0)
        .toList();
    out.sort((a, b) {
      final byBehind = AccountFilter.monthsBehind(b, now)
          .compareTo(AccountFilter.monthsBehind(a, now));
      if (byBehind != 0) return byBehind;
      return a.nextDueDate.compareTo(b.nextDueDate);
    });
    return out;
  }

  /// Greedily pack [accounts] (one installment each) into consecutive lots,
  /// each kept at or below [cap]. Order is preserved, so the most-unpaid
  /// accounts land in the earliest lots. Returns unsaved [Lot]s.
  static List<Lot> pack(
    List<RdAccount> accounts,
    DateTime now, {
    int cap = 20000,
    String mode = 'Cash',
  }) {
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
      // Start a new lot when adding this account would break the cap (unless
      // the current lot is empty — a lone account bigger than the cap still
      // gets its own lot rather than being dropped).
      if (current.isNotEmpty && running + amt > cap) flush();
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
