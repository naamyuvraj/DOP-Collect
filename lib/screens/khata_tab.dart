import 'package:flutter/material.dart';

import '../data/collection_repository.dart';
import '../models/collection.dart';
import '../models/khata.dart';
import '../theme/app_theme.dart';
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
        if (all.isEmpty) return _empty();

        final pages = KhataBook.fromCollections(all);
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            itemCount: pages.length + 1,
            itemBuilder: (_, i) =>
                i == 0 ? _lifetime(all, pages) : _monthCard(pages[i - 1]),
          ),
        );
      },
    );
  }

  /// Nothing collected yet. Says what will fill it, so the blank page isn't read
  /// as something being broken.
  Widget _empty() => ListView(
        padding: const EdgeInsets.fromLTRB(24, 60, 24, 40),
        children: [
          const Icon(Icons.menu_book_outlined,
              size: 44, color: AppTheme.inkFaint),
          const SizedBox(height: 14),
          Center(
            child: Text('Khata is empty',
                style: AppTheme.display(18, weight: FontWeight.w800)),
          ),
          const SizedBox(height: 8),
          Text(
            'Every collection you take from this customer on the Collect sheet '
            'appears here — the day, the amount, and the month\'s total.',
            textAlign: TextAlign.center,
            style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.45),
          ),
        ],
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
          Expanded(
              child: _stat('Entries', '${all.length}', AppTheme.inkMuted)),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(page.label,
                        style: AppTheme.display(16, weight: FontWeight.w800)),
                    Text(
                      '${page.visits} ${page.visits == 1 ? "visit" : "visits"}'
                      '${page.installments > 1 ? " · ${page.installments} installments" : ""}',
                      style: AppTheme.body(11.5, color: AppTheme.inkMuted),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(inr(page.total),
                      style: AppTheme.display(17, weight: FontWeight.w800)
                          .copyWith(color: AppTheme.green)),
                  // Shortfall, but only for a month that has actually finished.
                  // Saying "short ₹14,500" on the 2nd of a daily payer's month
                  // would be true and useless.
                  if (_isPast(page.month) &&
                      page.total < widget.monthlyAmount)
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
            const Icon(Icons.info_outline, size: 14, color: AppTheme.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: AppTheme.body(11.5, color: AppTheme.ink, height: 1.35)),
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
      for (var d = 1; d <= page.daysInMonth; d++)
        _dayCell(page, d, byDay[d]),
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
    return InkWell(
      onTap: paid ? () => _showDay(page, day) : null,
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(entries.first.dayLabel,
                        style:
                            AppTheme.display(16, weight: FontWeight.w800)),
                  ),
                  Text(inr(total),
                      style: AppTheme.display(16, weight: FontWeight.w800)
                          .copyWith(color: AppTheme.green)),
                ],
              ),
              const SizedBox(height: 12),
              ...entries.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle,
                          size: 15, color: AppTheme.green),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(c.timeLabel,
                            style: AppTheme.body(13, color: AppTheme.inkMuted)),
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
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
