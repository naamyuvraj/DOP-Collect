import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/collection_repository.dart';
import '../models/collection.dart';
import '../models/khata.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';
import '../util/format.dart';

/// One customer's khata — the paper book, on a phone.
///
/// Every swipe on the collect sheet already wrote a `collections` row; until now
/// nothing showed them back to the agent per customer. This is that page: a
/// month at a time, newest first, with the days he actually turned up marked on
/// a calendar.
///
/// The month total is a SUM over the days drawn beneath it, so the figure and
/// its entries can never disagree — the way a written total and its column can.
class KhataTab extends StatefulWidget {
  const KhataTab({
    super.key,
    required this.collections,
    required this.accountNumber,
    required this.monthlyAmount,
  });

  final CollectionRepository collections;
  final String accountNumber;

  /// The account's monthly RD, used to say how a month compares.
  final int monthlyAmount;

  @override
  State<KhataTab> createState() => _KhataTabState();
}

class _KhataTabState extends State<KhataTab> {
  late Future<List<Collection>> _future;

  /// The month the calendar is on. The khata used to render one card per month
  /// that HAD entries, which meant a month with nothing in it did not exist —
  /// and those are exactly the months you need to reach to key in a visit you
  /// missed. Paging by month reaches every month, empty or not.
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    _future = widget.collections.forAccount(widget.accountNumber);
  }

  Future<void> _reload() async {
    setState(() {
      _future = widget.collections.forAccount(widget.accountNumber);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Collection>>(
      future: _future,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final all = snap.data!;
        final pages = KhataBook.fromCollections(all);
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            children: [
              _lifetime(all, pages),
              _monthCard(_pageFor(all, _month)),
            ],
          ),
        );
      },
    );
  }

  /// One month's page, built whether or not anything was collected in it.
  KhataMonth _pageFor(List<Collection> all, DateTime month) {
    final entries = all
        .where((c) =>
            c.collectedAt.year == month.year &&
            c.collectedAt.month == month.month)
        .toList()
      ..sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
    return KhataMonth(month: month, entries: entries);
  }

  bool _isCurrentMonth(DateTime m) {
    final now = DateTime.now();
    return m.year == now.year && m.month == now.month;
  }

  Widget _monthArrow(IconData icon, VoidCallback? onTap) => IconButton(
        icon: Icon(icon,
            size: 22, color: onTap == null ? AppTheme.line : AppTheme.ink),
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      );

  /// The whole book at a glance, above the pages.
  Widget _lifetime(List<Collection> all, List<KhataMonth> pages) {
    final total = KhataBook.lifetimeTotal(all);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.card(),
      child: Row(
        children: [
          Expanded(child: _stat('Collected', inr(total), AppTheme.green)),
          Container(width: 1, height: 34, color: AppTheme.divider),
          Expanded(child: _stat('Months', '${pages.length}', AppTheme.accent)),
          Container(width: 1, height: 34, color: AppTheme.divider),
          Expanded(child: _stat('Entries', '${all.length}', AppTheme.inkMuted)),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) => Column(
        children: [
          Text(label, style: AppTheme.body(11.5, color: AppTheme.inkMuted)),
          const SizedBox(height: 4),
          Text(value,
              style: AppTheme.display(17, weight: FontWeight.w800)
                  .copyWith(color: color)),
        ],
      );

  /// True once [month] is over, so a shortfall is a fact rather than a
  /// mid-month snapshot.
  static bool _isPast(DateTime month) {
    final now = DateTime.now();
    return month.year < now.year ||
        (month.year == now.year && month.month < now.month);
  }

  /// One month: header, calendar, and the odd-cycle note when there is one.
  Widget _monthCard(KhataMonth page) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Step the calendar a month at a time, from the header that
              // already names the month — a separate nav row above the card
              // just printed the month name twice.
              _monthArrow(Icons.chevron_left_rounded,
                  () => setState(() =>
                      _month = DateTime(_month.year, _month.month - 1))),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(page.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.display(16, weight: FontWeight.w800)),
                    Text(
                      '${page.visits} ${page.visits == 1 ? "visit" : "visits"}'
                      '${page.installments > 1 ? " · ${page.installments} installments" : ""}',
                      style: AppTheme.body(11.5, color: AppTheme.inkMuted),
                    ),
                  ],
                ),
              ),
              // Paired with its month, not stranded at the far edge — the two
              // arrows are one control and belong either side of the thing
              // they move. Forward stops at the current month: there is
              // nothing to record in a month that has not happened.
              _monthArrow(
                  Icons.chevron_right_rounded,
                  _isCurrentMonth(page.month)
                      ? null
                      : () => setState(() =>
                          _month = DateTime(_month.year, _month.month + 1))),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(inr(page.total),
                      style: AppTheme.display(17, weight: FontWeight.w800)
                          .copyWith(color: AppTheme.green)),
                  // Shortfall, but only for a month that has actually finished.
                  // Saying "short ₹14,500" on the 2nd of a daily payer's month
                  // would be true and useless.
                  if (_isPast(page.month) && page.total < widget.monthlyAmount)
                    Text('short ${inr(widget.monthlyAmount - page.total)}',
                        style: AppTheme.body(11.5, color: AppTheme.red)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          _calendar(page),
          if (page.hasOtherCycle) ...[
            const SizedBox(height: 10),
            _note('Includes money booked to another month — an advance, or a '
                'payment made for the month just ended.'),
          ],
        ],
      ),
    );
  }

  Widget _note(String text) => Container(
        padding: const EdgeInsets.all(10),
        decoration: AppTheme.panel(AppTheme.focal, radius: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 14, color: AppTheme.amberOnFocal),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: AppTheme.body(11.5,
                      color: AppTheme.onFocal, height: 1.35)),
            ),
          ],
        ),
      );

  /// Month grid, Monday-first. A day he collected is filled and tappable; the
  /// rest are quiet, so the pattern of his round is visible at a glance.
  Widget _calendar(KhataMonth page) {
    const heads = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final byDay = page.byDay;
    final blanks = page.firstWeekday - 1; // Monday = 1
    final cells = <Widget>[
      for (final h in heads)
        Center(
          child: Text(h,
              style: AppTheme.body(10.5,
                  color: AppTheme.inkFaint, weight: FontWeight.w700)),
        ),
      for (var i = 0; i < blanks; i++) const SizedBox.shrink(),
      for (var d = 1; d <= page.daysInMonth; d++) _dayCell(page, d, byDay[d]),
    ];

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      children: cells,
    );
  }

  Widget _dayCell(KhataMonth page, int day, int? amount) {
    final paid = amount != null;
    // Every day he could have collected on opens, not just the ones that
    // already have an entry — that is what makes the calendar a way IN to the
    // khata rather than only a picture of it. Future days stay inert: there is
    // no such thing as money taken tomorrow.
    final date = DateTime(page.month.year, page.month.month, day);
    final today = DateTime.now();
    final isFuture = date.isAfter(DateTime(today.year, today.month, today.day));
    return InkWell(
      onTap: isFuture ? null : () => _showDay(page, day),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: paid
            ? AppTheme.panel(AppTheme.greenSoft, radius: 8)
            : const BoxDecoration(),
        child: Center(
          child: Text(
            '$day',
            style: AppTheme.body(
              12,
              weight: paid ? FontWeight.w800 : FontWeight.w400,
              color: paid ? AppTheme.green : AppTheme.inkFaint,
            ),
          ),
        ),
      ),
    );
  }

  /// What was taken on one day. A daily payer can have two handovers in a day,
  /// so this lists them rather than showing a single figure.
  void _showDay(KhataMonth page, int day) {
    final entries = page.onDay(day);
    final total = entries.fold(0, (s, c) => s + c.amount);
    final date = DateTime(page.month.year, page.month.month, day);
    final dayLabel = DateFormat('dd-MMM-yyyy').format(date);
    showModalBottomSheet<void>(
      context: context,
      // Painted INSIDE the builder, not passed as a route argument: a route
      // argument is evaluated once when the sheet opens, so a theme change
      // while it is up left a dark panel wearing light-mode type (or the
      // reverse). Anything inside the builder rebuilds with the tree.
      backgroundColor: Colors.transparent,
      builder: (_) => DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppTheme.cardRadius)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // From the tapped date, not from entries.first — every
                    // day opens now, and an empty one has no first entry to
                    // read a label off.
                    Expanded(
                      child: Text(dayLabel,
                          style: AppTheme.display(16, weight: FontWeight.w800)),
                    ),
                    if (entries.isNotEmpty)
                      Text(inr(total),
                          style: AppTheme.display(16, weight: FontWeight.w800)
                              .copyWith(color: AppTheme.green)),
                  ],
                ),
                const SizedBox(height: 12),
                if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('Nothing collected on this day.',
                        style: AppTheme.body(13, color: AppTheme.inkFaint)),
                  ),
                ...entries.map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 15, color: AppTheme.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(c.timeLabel,
                              style:
                                  AppTheme.body(13, color: AppTheme.inkMuted)),
                        ),
                        if (c.installments > 1)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Text('${c.installments} months',
                                style: AppTheme.body(11.5,
                                    color: AppTheme.inkFaint)),
                          ),
                        Text(inr(c.amount),
                            style: AppTheme.body(13, weight: FontWeight.w700)),
                        // Correct a mistyped figure. Closes the sheet first so
                        // the dialog is not stacked on a sheet he then has to
                        // dismiss twice.
                        IconButton(
                          icon: Icon(Icons.edit_outlined,
                              size: 17, color: AppTheme.inkFaint),
                          tooltip: 'Correct this amount',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            Navigator.of(context).pop();
                            _editEntry(c);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                PushButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _addEntry(date);
                  },
                  color: AppTheme.black,
                  child: Text(entries.isEmpty
                      ? 'Add a collection'
                      : 'Add another collection'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Record a handover straight onto a day in the khata.
  ///
  /// The calendar is where he already looks to check a customer, so it is the
  /// natural place to key in a visit he missed at the door. The date is stated
  /// in full and cannot be changed here — he picked it by tapping it, and a
  /// date field in this dialog would only be a second chance to get it wrong.
  Future<void> _addEntry(DateTime date) async {
    final controller = TextEditingController();
    final now = DateTime.now();
    final isToday = DateTime(now.year, now.month, now.day) ==
        DateTime(date.year, date.month, date.day);
    // Months this hands over. A monthly customer pays the whole installment in
    // one go, and paying two or three ahead is normal — typing the arithmetic
    // by hand and leaving the entry booked as one month understated the RD.
    var months = 1;
    final monthly = widget.monthlyAmount;
    final entered = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(isToday ? 'Add a collection' : 'Add for an earlier day',
              style: AppTheme.display(18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(DateFormat('EEEE, dd-MMM-yyyy').format(date),
                  style: AppTheme.body(13,
                      weight: FontWeight.w700, color: AppTheme.inkMuted)),
              if (!isToday)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      'This lands in that day\'s khata and that month\'s '
                      'total, not today\'s.',
                      style: AppTheme.body(12,
                          color: AppTheme.inkFaint, height: 1.4)),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                style: AppTheme.display(22, weight: FontWeight.w800),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: AppTheme.display(22, weight: FontWeight.w800),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setLocal(() => months = 1),
              ),
              if (monthly > 0) ...[
                const SizedBox(height: 12),
                Text('OR PAY THE INSTALLMENT',
                    style: AppTheme.body(10.5,
                        weight: FontWeight.w800,
                        color: AppTheme.inkFaint,
                        spacing: 0.4)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final n in const [1, 2, 3])
                      GestureDetector(
                        onTap: () => setLocal(() {
                          months = n;
                          controller.text = '${monthly * n}';
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: AppTheme.card(
                              fill: months == n
                                  ? AppTheme.black
                                  : AppTheme.surface,
                              radius: 10,
                              offset: months == n
                                  ? AppTheme.faceOffsetPressed
                                  : 0),
                          child: Text(
                              n == 1
                                  ? 'Full month · ${inr(monthly)}'
                                  : '$n months · ${inr(monthly * n)}',
                              style: AppTheme.body(12.5,
                                  weight: FontWeight.w700,
                                  color: months == n
                                      ? AppTheme.onAccent
                                      : AppTheme.ink)),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Cancel',
                  style: AppTheme.body(14, color: AppTheme.inkMuted)),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(int.tryParse(controller.text.trim())),
              child: Text('Add',
                  style: AppTheme.body(14,
                      weight: FontWeight.w700, color: AppTheme.ink)),
            ),
          ],
        ),
      ),
    );
    if (!mounted || entered == null || entered <= 0) return;

    // Stamped with the clock time now, but on the day he chose, so the khata
    // reads in the order things were keyed while the entry still belongs to
    // the day it happened. The cycle comes off that date and never off today —
    // otherwise a payment keyed late would drift into the wrong month.
    final at = DateTime(date.year, date.month, date.day, now.hour, now.minute);
    await widget.collections.add(Collection(
      accountNumber: widget.accountNumber,
      amount: entered,
      collectedAt: at,
      cycleYm: Collection.cycleOf(at),
      installments: months,
    ));
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('${inr(entered)} added to '
            '${DateFormat('dd-MMM').format(date)}'),
        duration: const Duration(seconds: 3),
      ));
  }

  /// Correct one recorded handover.
  ///
  /// Two steps on purpose. The first asks for the figure; the second states
  /// the change in words and names what it moves, because this rewrites a
  /// customer's khata and the month's total — and the agent reconciles cash
  /// against both. The door time is never touched.
  Future<void> _editEntry(Collection c) async {
    final controller = TextEditingController(text: c.amount.toString());
    final entered = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Correct the amount', style: AppTheme.display(18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${c.dayLabel} · ${c.timeLabel}',
                style: AppTheme.body(13, color: AppTheme.inkMuted)),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: AppTheme.display(22, weight: FontWeight.w800),
              decoration: InputDecoration(
                prefixText: '₹ ',
                prefixStyle: AppTheme.display(22, weight: FontWeight.w800),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel',
                style: AppTheme.body(14, color: AppTheme.inkMuted)),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(v);
            },
            child: Text('Next',
                style: AppTheme.body(14,
                    weight: FontWeight.w700, color: AppTheme.ink)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (entered == null || entered <= 0 || entered == c.amount) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Change this entry?', style: AppTheme.display(18)),
        content: Text(
          '${c.dayLabel} will change from ${inr(c.amount)} to '
          '${inr(entered)}.\n\nThis updates the khata and that month\'s '
          'total. The time it was collected does not change.',
          style: AppTheme.body(14, color: AppTheme.inkMuted, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Keep ${inr(c.amount)}',
                style: AppTheme.body(14, color: AppTheme.inkMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Change it',
                style: AppTheme.body(14,
                    weight: FontWeight.w700, color: AppTheme.ink)),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    await widget.collections.update(c.copyWith(amount: entered));
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('Changed to ${inr(entered)}'),
        duration: const Duration(seconds: 3),
      ));
  }
}
