import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/account_repository.dart';
import '../../data/app_settings.dart';
import '../../data/collection_repository.dart';
import '../../data/lot_repository.dart';
import '../../models/collection.dart';
import '../../models/collection_round.dart';
import '../../models/daily_rule.dart';
import '../../models/lot_packing.dart';
import '../../models/rd_account.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../account_list_screen.dart';
import 'collect_row.dart';
import 'day_close_screen.dart';
import 'route_order_screen.dart';

/// The collect sheet — the screen he holds while walking his round.
///
/// One gesture per customer: swipe right to record the money. No dialog, no
/// date picker, no navigation. The amount is whatever that customer hands over
/// (their full installment, or their daily amount), the time is now, and every
/// entry is undoable, so speed never costs him accuracy.
class CollectScreen extends StatefulWidget {
  const CollectScreen({
    super.key,
    required this.accounts,
    required this.collections,
    required this.lots,
    this.revision = 0,
  });

  final AccountRepository accounts;
  final CollectionRepository collections;
  final LotRepository lots;

  /// Bumped by the shell so the sheet re-reads on entry (it lives in an
  /// IndexedStack and would otherwise hold its first query forever).
  final int revision;

  @override
  State<CollectScreen> createState() => _CollectScreenState();
}

class _CollectScreenState extends State<CollectScreen> {
  List<RoundEntry>? _rows;
  List<Collection> _today = const [];
  RoundSort _sort = RoundSort.due;

  /// What one swipe takes, for every row at once. Daily is the default because
  /// that is how most of a book pays. It's a screen-level switch rather than a
  /// per-customer mode, so he flips it once for the round he's walking instead
  /// of configuring 465 people — and it is remembered, so he doesn't flip it
  /// again every morning.
  bool _daily = true;
  DayCloseState _dayState = DayCloseState.open;

  /// Which customers the sheet is showing.
  RoundFilter _filter = RoundFilter.all;

  // The round's source data, held so a collection can update one row in place.
  // Re-reading all 480 accounts and re-sorting after every swipe was both slow
  // and disorienting: the customer he just collected from jumped into another
  // group and every row below moved up, under his thumb, mid-round.
  List<RdAccount> _accounts = const [];
  List<Collection> _cycle = const [];
  Set<String> _listed = const {};
  DailyRule _rule = DailyRule.standard;
  String _query = '';
  Timer? _debounce;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CollectScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final accounts = await widget.accounts.all();
    final cycle = await widget.collections.forCycle(Collection.cycleOf(now));
    final today = await widget.collections.forDay(now);
    final lots = await widget.lots.all();
    final dayState =
        await AppSettings.dayCloseState(now, CollectionRound.total(today));
    final rule = await AppSettings.dailyRule();
    final daily = await AppSettings.collectDailyMode();
    if (!mounted) return;
    // Default to his round once he has arranged one — that's the order he
    // walks, and re-picking it every morning would be a chore.
    final hasRoute = accounts.any((a) => a.routeOrder != null);
    final listed = LotPacking.listedThisCycle(lots, now);
    setState(() {
      _sort = hasRoute ? RoundSort.route : _sort;
      _today = today;
      _accounts = accounts;
      _cycle = cycle;
      _listed = listed;
      _rule = rule;
      _daily = daily;
      // "Counted" only holds while the figure he counted still matches what is
      // in the bag. Collect again after closing and it re-arms, so a stale tick
      // can never tell him he's reconciled when he isn't.
      _dayState = dayState;
      _rows = CollectionRound.build(
        accounts,
        cycle,
        now,
        sort: _sort,
        alreadyListed: listed,
        rule: rule,
      );
    });
  }

  Future<void> _resort(RoundSort sort) async {
    setState(() => _sort = sort);
    await _load();
  }

  /// Re-grade every row against the current ledger **without re-sorting**.
  ///
  /// This is what a collection triggers. Positions are deliberately frozen: he
  /// is walking a round and reading down the list, so a row that re-sorts the
  /// moment he swipes moves the next customer out from under his thumb. The
  /// order settles again on the next full [_load] — entering the tab, changing
  /// the sort, or pulling to refresh.
  void _regradeInPlace() {
    final rows = _rows;
    if (rows == null) return;
    final now = DateTime.now();
    final progress =
        CollectionRound.progressByAccount(_accounts, _cycle, rule: _rule);
    _rows = [
      for (final r in rows)
        if (progress[r.accountNumber] case final p?)
          RoundEntry(
            progress: p,
            group: CollectionRound.groupFor(
                r.account, p, now, _listed.contains(r.accountNumber)),
          )
        else
          r
    ];
  }

  /// Record one handover and offer an immediate undo.
  ///
  /// Written straight through with no confirmation: the entry is reversible,
  /// and a confirm step on every house is what makes the incumbent app cost six
  /// taps per customer.
  Future<void> _collect(RoundEntry row, {int? amount, int? installments}) async {
    final p = row.progress;
    final value = amount ?? (_daily ? p.dailyNext : p.monthlyNext);
    if (value <= 0) return;
    final now = DateTime.now();
    final saved = await widget.collections.add(Collection(
      accountNumber: row.accountNumber,
      amount: value,
      // A daily slice carries no month of its own — the month is credited once
      // the running total reaches the installment.
      installments: installments ?? (_daily ? 0 : 1),
      collectedAt: now,
      cycleYm: Collection.cycleOf(now),
    ));
    unawaited(HapticFeedback.mediumImpact()); // confirmation without looking
    if (!mounted) return;
    // Update the row where it stands instead of re-reading the whole round.
    setState(() {
      _cycle = [saved, ..._cycle];
      _today = [saved, ..._today];
      _dayState = DayCloseState.open; // the bag grew — any earlier count is stale
      _regradeInPlace();
    });
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('${inr(value)} · ${row.account.customerName}'),
        // Short on purpose: he swipes house after house, and a 4-second bar sat
        // over the next rows the whole time. Undo is still on the row itself
        // (swipe left), so this only has to catch an immediate mistake.
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _remove(saved),
        ),
      ));
  }

  Future<void> _undoLast(RoundEntry row) async {
    final last =
        row.progress.entries.isEmpty ? null : row.progress.entries.first;
    if (last == null) return;
    await _remove(last);
  }

  /// Drop one recorded handover, in place — the mirror of [_collect], so an
  /// undo doesn't re-sort the round either.
  Future<void> _remove(Collection c) async {
    final id = c.id;
    if (id == null) return;
    await widget.collections.remove(id);
    if (!mounted) return;
    setState(() {
      _cycle = [for (final x in _cycle) if (x.id != id) x];
      _today = [for (final x in _today) if (x.id != id) x];
      _dayState = DayCloseState.open; // the bag shrank — any earlier count is stale
      _regradeInPlace();
    });
  }

  /// Count the cash against the ledger before the day's memory goes cold.
  Future<void> _openDayClose() async {
    final accounts = await widget.accounts.all();
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DayCloseScreen(
        collections: widget.collections,
        accounts: accounts,
        day: DateTime.now(),
      ),
    ));
    if (!mounted) return;
    // Reload either way — he may have undone an entry in there, and the closed
    // marker changes the header.
    if (changed != null) await _load();
  }

  Future<void> _openRouteOrder() async {
    final rows = _rows;
    if (rows == null) return;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => RouteOrderScreen(
        repo: widget.accounts,
        accounts: rows.map((r) => r.account).toList(),
      ),
    ));
    if (changed == true && mounted) {
      setState(() => _sort = RoundSort.route);
      await _load();
    }
  }

  List<RoundEntry> get _visible {
    var rows = _rows ?? const <RoundEntry>[];
    if (_filter != RoundFilter.all) {
      rows = rows.where(_filter.matches).toList();
    }
    if (_query.isEmpty) return rows;
    final q = _query.toLowerCase();
    return rows
        .where((r) =>
            r.account.customerName.toLowerCase().contains(q) ||
            r.accountNumber.contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null) {
      return const SafeArea(
          child: Center(child: CircularProgressIndicator()));
    }
    if (rows.isEmpty) return SafeArea(child: _empty());

    final visible = _visible;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _bagHeader(rows),
          _modeToggle(),
          _countLine(rows),
          _toolbar(),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text('No customer matches "$_query".',
                        style: AppTheme.body(14, color: AppTheme.inkMuted)))
                : _sheet(visible),
          ),
        ],
      ),
    );
  }

  /// What's in his bag today, and what the round still owes — the two numbers
  /// he actually needs while walking.
  Widget _bagHeader(List<RoundEntry> rows) {
    final bag = CollectionRound.total(_today);
    final outstanding = CollectionRound.outstanding(rows);
    final done = rows.where((r) => r.group == RoundGroup.collected).length;
    final owing = rows
        .where((r) =>
            r.group == RoundGroup.toCollect || r.group == RoundGroup.partial)
        .length;

    // The postal ₹20,000 list cap, filling as he collects — so the list is
    // forming while he walks instead of being a separate month-end chore.
    final capped = bag % LotPacking.defaultCap;
    final room = LotPacking.defaultCap - capped;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: AppTheme.card(fill: AppTheme.focal),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('IN YOUR BAG TODAY', style: AppTheme.label(AppTheme.ink)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(inr(bag), style: AppTheme.display(30, weight: FontWeight.w800)),
              const SizedBox(width: 10),
              Flexible(
                child: Text('${_today.length} collections',
                    style: AppTheme.body(13, color: AppTheme.inkMuted)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: capped / LotPacking.defaultCap,
              minHeight: 8,
              backgroundColor: Colors.black.withValues(alpha: 0.10),
              valueColor: const AlwaysStoppedAnimation(AppTheme.black),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  bag == 0
                      ? 'Swipe a customer right when they pay you.'
                      : '${inr(room)} more fits this list · $done collected, '
                          '$owing to go (${inr(outstanding)})',
                  style: AppTheme.body(12.5, color: AppTheme.inkMuted),
                ),
              ),
              // Day close sits on the bag card because that's the number he is
              // reconciling — counting cash is the last thing he does with it.
              if (bag > 0) ...[
                const SizedBox(width: 8),
                _dayCloseButton(),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// The day-close control, which has to state exactly what happened.
  ///
  /// A tick is a claim that the cash was counted and agreed with the ledger —
  /// so it is reserved for [DayCloseState.reconciled]. Closing without counting
  /// is a real, allowed outcome and says so plainly; it must never wear the
  /// same tick as a day he actually counted.
  Widget _dayCloseButton() {
    final (String label, IconData? icon, bool solid) = switch (_dayState) {
      DayCloseState.reconciled => ('Counted', Icons.check_rounded, false),
      DayCloseState.closedUncounted =>
        ('Closed · not counted', Icons.remove_done_rounded, false),
      DayCloseState.open => ('Count cash', null, true),
    };
    return GestureDetector(
      onTap: _openDayClose,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: solid ? AppTheme.black : Colors.transparent,
          borderRadius: BorderRadius.circular(17),
          border: solid
              ? null
              : Border.all(color: AppTheme.ink.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: AppTheme.ink),
              const SizedBox(width: 5),
            ],
            Text(label,
                style: AppTheme.body(12.5,
                    weight: FontWeight.w800,
                    color: solid ? Colors.white : AppTheme.ink)),
          ],
        ),
      ),
    );
  }

  /// Daily | Full month — decides what one swipe takes, across every row.
  Widget _modeToggle() {
    Widget seg(String label, bool daily) {
      final on = _daily == daily;
      return Expanded(
        child: GestureDetector(
          onTap: () {
            setState(() => _daily = daily);
            unawaited(AppSettings.setCollectDailyMode(daily));
          },
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AppTheme.black : Colors.transparent,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Text(label,
                style: AppTheme.body(13.5,
                    weight: FontWeight.w800,
                    color: on ? Colors.white : AppTheme.inkMuted)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: AppTheme.card(radius: 23),
        child: Row(children: [seg('Daily', true), seg('Full month', false)]),
      ),
    );
  }

  /// How many customers are on the sheet in total, and how many still owe.
  ///
  /// The group headings below each carry their own count, and on a 480-account
  /// book the first one ("TO COLLECT 343") reads like a total when it isn't —
  /// the rest are further down under the other headings. This line states the
  /// real total so nothing looks missing.
  Widget _countLine(List<RoundEntry> rows) {
    final owing = rows.where(RoundFilter.toCollect.matches).length;
    final paid = rows.where(RoundFilter.paid.matches).length;

    Widget chip(RoundFilter f, int n) {
      final on = _filter == f;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => setState(() => _filter = f),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AppTheme.black : AppTheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: on ? AppTheme.black : AppTheme.line),
            ),
            child: Text('${f.label} $n',
                style: AppTheme.body(12.5,
                    weight: FontWeight.w700,
                    color: on ? Colors.white : AppTheme.inkMuted)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          chip(RoundFilter.all, rows.length),
          chip(RoundFilter.toCollect, owing),
          chip(RoundFilter.paid, paid),
        ],
      ),
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: AppTheme.card(radius: 12),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded,
                      size: 19, color: AppTheme.inkFaint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: _onSearch,
                      style: AppTheme.body(14.5),
                      cursorColor: AppTheme.accent,
                      decoration: InputDecoration(
                        hintText: 'Find a customer',
                        hintStyle:
                            AppTheme.body(14.5, color: AppTheme.inkFaint),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  if (_searchCtrl.text.isNotEmpty)
                    GestureDetector(
                      onTap: () => setState(() {
                        _searchCtrl.clear();
                        _query = '';
                      }),
                      child: const Icon(Icons.close_rounded,
                          size: 19, color: AppTheme.inkMuted),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _sortButton(),
        ],
      ),
    );
  }

  /// The plain account list this tab replaced — searchable, sortable, and the
  /// way into a customer's full profile. Kept one tap away rather than gone.
  void _openAllAccounts() {
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) => AccountListScreen(repo: widget.accounts)))
        .then((_) => _load());
  }

  Widget _sortButton() {
    return PopupMenuButton<Object>(
      tooltip: 'Order',
      color: AppTheme.surface,
      onSelected: (v) {
        if (v == 'arrange') {
          _openRouteOrder();
        } else if (v == 'all') {
          _openAllAccounts();
        } else if (v is RoundSort) {
          _resort(v);
        }
      },
      itemBuilder: (_) => [
        for (final s in RoundSort.values)
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                Icon(
                    s == _sort
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: s == _sort ? AppTheme.black : AppTheme.inkFaint),
                const SizedBox(width: 10),
                Text(s.label, style: AppTheme.body(14)),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'arrange',
          child: Row(
            children: [
              const Icon(Icons.route_rounded, size: 18, color: AppTheme.black),
              const SizedBox(width: 10),
              Text('Arrange my route', style: AppTheme.body(14)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'all',
          child: Row(
            children: [
              const Icon(Icons.account_balance_wallet_rounded,
                  size: 18, color: AppTheme.black),
              const SizedBox(width: 10),
              Text('All accounts', style: AppTheme.body(14)),
            ],
          ),
        ),
      ],
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: AppTheme.card(radius: 12),
        child: Row(
          children: [
            const Icon(Icons.sort_rounded, size: 18, color: AppTheme.black),
            const SizedBox(width: 6),
            Text(_sort.label,
                style: AppTheme.body(13.5, weight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  /// The sheet, with a small heading each time the group changes.
  Widget _sheet(List<RoundEntry> rows) {
    final showShortfall = CollectionRound.nearCycleEnd(DateTime.now());
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 140),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        final first = i == 0 || rows[i - 1].group != row.group;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (first)
              _groupHeading(row.group, rows, showShortfall: showShortfall),
            CollectRow(
              entry: row,
              daily: _daily,
              onCollect: () => _collect(row),
              onCollectAmount: (amt, inst) =>
                  _collect(row, amount: amt, installments: inst),
              onUndo: () => _undoLast(row),
              onSetDaily: (amt) async {
                await widget.accounts.setDailyAmount(row.accountNumber, amt);
                await _load();
              },
            ),
          ],
        );
      },
    );
  }

  Widget _groupHeading(RoundGroup group, List<RoundEntry> rows,
      {required bool showShortfall}) {
    // "343 of 480", never a bare "343" — a group count on its own reads as the
    // size of the whole book and makes the other 137 look lost.
    final count = '${rows.where((r) => r.group == group).length} '
        'of ${rows.length}';
    final (String title, Color tint) = switch (group) {
      RoundGroup.toCollect => ('To collect', AppTheme.black),
      RoundGroup.partial => (
          showShortfall ? 'Short this month' : 'Part paid',
          AppTheme.amber
        ),
      RoundGroup.collected => ('Collected', AppTheme.green),
      RoundGroup.settled => ('Nothing to collect', AppTheme.inkFaint),
    };

    // Late in the cycle, part-paid stops being normal progress and becomes the
    // list he has to chase — say so, with the money still missing.
    String? note;
    if (group == RoundGroup.partial && showShortfall) {
      final short = rows
          .where((r) => r.group == RoundGroup.partial)
          .fold(0, (s, r) => s + r.progress.remaining);
      note = '${inr(short)} still to come before list day';
    } else if (group == RoundGroup.settled) {
      note = 'Already on a list, or paid ahead';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text('${title.toUpperCase()}  $count',
              style: AppTheme.label(AppTheme.inkMuted)),
          if (note != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(note,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body(11.5, color: AppTheme.inkFaint)),
            ),
          ],
        ],
      ),
    );
  }

  void _onSearch(String v) {
    setState(() {}); // reflect the clear button at once
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.checklist_rounded,
                size: 48, color: AppTheme.inkFaint),
            const SizedBox(height: 14),
            Text('Nothing to collect yet',
                style: AppTheme.display(18, weight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              'Sync your accounts from the portal and your round will appear '
              'here.',
              textAlign: TextAlign.center,
              style: AppTheme.body(13.5, color: AppTheme.inkMuted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
