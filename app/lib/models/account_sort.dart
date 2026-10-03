import 'rd_account.dart';

/// Ways to sort a list of accounts, shared by the "All Accounts" tab and the
/// New-list builder. A null selection means the screen's own default order
/// (natural order for the tab, smart priority for the list builder).
enum AccountSort {
  amountDesc('Amount · high'),
  amountAsc('Amount · low'),
  dueAsc('Due · earliest'),
  dueDesc('Due · latest');

  const AccountSort(this.label);

  /// Short chip label.
  final String label;

  Comparator<RdAccount> get comparator {
    switch (this) {
      case AccountSort.amountDesc:
        return (a, b) => b.denominationAmount.compareTo(a.denominationAmount);
      case AccountSort.amountAsc:
        return (a, b) => a.denominationAmount.compareTo(b.denominationAmount);
      case AccountSort.dueAsc:
        return (a, b) => a.nextDueDate.compareTo(b.nextDueDate);
      case AccountSort.dueDesc:
        return (a, b) => b.nextDueDate.compareTo(a.nextDueDate);
    }
  }
}
