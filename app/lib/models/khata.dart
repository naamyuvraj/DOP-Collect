import 'package:intl/intl.dart';

import 'collection.dart';

/// One month of a customer's khata — the page you'd turn to in a paper book.
///
/// Built from the `collections` ledger, never stored. The monthly total is a SUM
/// over the days it shows, so the two can't drift apart the way a written-down
/// total and its entries do.
class KhataMonth {
  KhataMonth({
    required this.month,
    required this.entries,
  });

  /// First of the month this page covers.
  final DateTime month;

  /// Every handover on this page, newest first.
  final List<Collection> entries;

  String get label => DateFormat('MMMM yyyy').format(month);
  String get shortLabel => DateFormat('MMM yyyy').format(month);

  /// What the customer handed over this month.
  int get total => entries.fold(0, (s, c) => s + c.amount);

  /// Months of RD covered — more than the visit count when someone pays ahead.
  int get installments => entries.fold(0, (s, c) => s + c.installments);

  /// Days he actually turned up. A daily payer shows ~26, a monthly one shows 1.
  int get visits => byDay.length;

  /// day-of-month → rupees taken that day. What the calendar paints.
  Map<int, int> get byDay {
    final m = <int, int>{};
    for (final c in entries) {
      final d = c.collectedAt.day;
      m[d] = (m[d] ?? 0) + c.amount;
    }
    return m;
  }

  /// Entries on one day, newest first — for the day tap-through.
  List<Collection> onDay(int day) =>
      entries.where((c) => c.collectedAt.day == day).toList();

  /// True when this page holds money booked against a DIFFERENT cycle — an
  /// advance, or a payment made on the 1st for the month just ended. Surfaced
  /// rather than silently filed under the wrong month.
  bool get hasOtherCycle {
    final own = Collection.cycleOf(month);
    return entries.any((c) => c.cycleYm != own);
  }

  /// Number of days in this month — the calendar grid needs it.
  int get daysInMonth => DateTime(month.year, month.month + 1, 0).day;

  /// Weekday of the 1st, Monday = 1 … Sunday = 7. Drives the leading blanks.
  int get firstWeekday => DateTime(month.year, month.month, 1).weekday;
}

/// Groups a customer's ledger into khata pages.
class KhataBook {
  KhataBook._();

  /// One page per month in which money actually changed hands, newest first.
  ///
  /// Grouped by **when the cash was taken**, not by `cycle_ym`. A calendar is a
  /// record of days, so a payment handed over on 1 August belongs on August's
  /// page even when it settles July's installment — [KhataMonth.hasOtherCycle]
  /// flags that case instead of hiding it. Months with nothing in them are
  /// omitted, so a book that started in June doesn't open on empty pages.
  static List<KhataMonth> fromCollections(List<Collection> all) {
    final byMonth = <String, List<Collection>>{};
    for (final c in all) {
      final key = DateFormat('yyyy-MM').format(c.collectedAt);
      (byMonth[key] ??= []).add(c);
    }

    final pages = byMonth.entries.map((e) {
      final parts = e.key.split('-');
      final month = DateTime(int.parse(parts[0]), int.parse(parts[1]));
      final entries = [...e.value]
        ..sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
      return KhataMonth(month: month, entries: entries);
    }).toList();

    pages.sort((a, b) => b.month.compareTo(a.month));
    return pages;
  }

  /// Everything the customer has ever handed over.
  static int lifetimeTotal(List<Collection> all) =>
      all.fold(0, (s, c) => s + c.amount);
}
