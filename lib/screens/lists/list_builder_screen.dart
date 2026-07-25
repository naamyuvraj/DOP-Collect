import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/account_repository.dart';
import '../../services/analytics.dart';
import '../../data/lot_repository.dart';
import '../../models/lot.dart';
import '../../models/rd_account.dart';
import '../../models/summaries.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';

/// Build a lot: accounts open sorted most-unpaid first; add installments per
/// account with a hard ₹20,000 total cap. Saving stores the lot (as a Group)
/// and marks those accounts Deposited.
class ListBuilderScreen extends StatefulWidget {
  const ListBuilderScreen({
    super.key,
    required this.accounts,
    required this.lots,
  });
  final AccountRepository accounts;
  final LotRepository lots;

  /// A lot's total must not exceed this.
  static const lotCap = 20000;

  @override
  State<ListBuilderScreen> createState() => _ListBuilderScreenState();
}

class _ListBuilderScreenState extends State<ListBuilderScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  Future<List<RdAccount>>? _future;

  /// accountNumber -> installments selected (>=1 means included).
  final Map<String, int> _selected = {};
  final Map<String, RdAccount> _byNumber = {};

  int get _count => _selected.length;
  int get _total => _selected.entries
      .fold(0, (s, e) => s + (_byNumber[e.key]?.denominationAmount ?? 0) * e.value);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    _future = (_query.isEmpty
            ? widget.accounts.all()
            : widget.accounts.search(_query))
        .then((list) {
      for (final a in list) {
        _byNumber[a.accountNumber] = a;
      }
      return _sortMostUnpaid(list);
    });
  }

  /// Most-unpaid first: most months overdue, then earliest due date.
  List<RdAccount> _sortMostUnpaid(List<RdAccount> list) {
    final now = DateTime.now();
    final out = [...list];
    out.sort((a, b) {
      final byBehind = AccountFilter.monthsBehind(b, now)
          .compareTo(AccountFilter.monthsBehind(a, now));
      if (byBehind != 0) return byBehind;
      return a.nextDueDate.compareTo(b.nextDueDate);
    });
    return out;
  }

  void _setInstallments(RdAccount a, int value) {
    final denom = a.denominationAmount;
    final current = _selected[a.accountNumber] ?? 0;
    final prospective = _total - denom * current + denom * (value < 0 ? 0 : value);
    if (value > 0 && prospective > ListBuilderScreen.lotCap) {
      _capReached();
      return;
    }
    setState(() {
      _byNumber[a.accountNumber] = a;
      if (value <= 0) {
        _selected.remove(a.accountNumber);
      } else {
        _selected[a.accountNumber] = value;
      }
    });
  }

  void _capReached() => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Lot total can\'t exceed ${inr(ListBuilderScreen.lotCap)}.')),
      );

  Future<void> _create() async {
    if (_selected.isEmpty) return;
    final items = _selected.entries.map((e) {
      final a = _byNumber[e.key]!;
      return LotItem(
        accountNumber: a.accountNumber,
        customerName: a.customerName,
        denomination: a.denominationAmount,
        installments: e.value,
      );
    }).toList();

    await widget.lots.save(Lot(
      createdAt: DateTime.now(),
      mode: 'Cash',
      items: items,
    ));
    unawaited(Analytics.track(
        'lot_created', {'accounts': items.length, 'amount': _total}));
    // Mark the collected accounts Deposited for this cycle.
    for (final n in _selected.keys) {
      await widget.accounts.setStatus(n, CollectionStatus.deposited);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Lot created · ${items.length} accounts · '
          '${inr(_total)}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capPct = (_total / ListBuilderScreen.lotCap).clamp(0.0, 1.0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Lot'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(66),
          child: Container(
            width: double.infinity,
            color: Colors.transparent,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _headerStat('Selected', '$_count'),
                    _headerStat('Total',
                        '${inr(_total)} / ${inr(ListBuilderScreen.lotCap)}'),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: capPct,
                    minHeight: 6,
                    backgroundColor: AppTheme.line,
                    color: capPct >= 1.0 ? AppTheme.red : AppTheme.green,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _searchRow(),
          Expanded(
            child: FutureBuilder<List<RdAccount>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snap.data!;
                if (list.isEmpty) {
                  return Center(
                    child: Text('No accounts',
                        style: AppTheme.body(14, color: AppTheme.inkMuted)),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 2),
                  itemBuilder: (_, i) => _row(list[i]),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: _count == 0
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.playlist_add_check, size: 20),
              label: Text('Create Lot ($_count)'),
            ),
    );
  }

  Widget _headerStat(String label, String value) => Row(
        children: [
          Text('$label : ',
              style: AppTheme.body(14, color: AppTheme.inkMuted)),
          Text(value, style: AppTheme.display(18, weight: FontWeight.w600)),
        ],
      );

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: AppTheme.card(radius: 10),
        child: Row(
          children: [
            const Icon(Icons.search, color: AppTheme.inkFaint, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() {
                  _query = v;
                  _reload();
                }),
                style: AppTheme.body(15),
                cursorColor: AppTheme.accent,
                decoration: InputDecoration(
                  hintText: 'Search name or account',
                  hintStyle: AppTheme.body(15, color: AppTheme.inkFaint),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(RdAccount a) {
    final installments = _selected[a.accountNumber] ?? 0;
    final selected = installments > 0;
    return Container(
      color: selected ? AppTheme.greenSoft : AppTheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(a.customerName,
                          style:
                              AppTheme.display(16, weight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (a.serial > 0)
                      Text('  #${a.serial}',
                          style: AppTheme.body(13,
                              weight: FontWeight.w600, color: AppTheme.accent)),
                  ],
                ),
                const SizedBox(height: 2),
                Text('#${a.accountNumber}',
                    style: AppTheme.body(12, color: AppTheme.inkMuted)),
                const SizedBox(height: 4),
                Text('Inst. ${inr(a.denominationAmount)} '
                    '(${a.monthsPaid} paid) · due ${a.dueDateIso}',
                    style: AppTheme.body(12, color: AppTheme.inkMuted)),
              ],
            ),
          ),
          _stepper(a, installments),
        ],
      ),
    );
  }

  Widget _stepper(RdAccount a, int installments) {
    return Row(
      children: [
        _circleBtn(Icons.remove, AppTheme.red,
            () => _setInstallments(a, installments - 1)),
        SizedBox(
          width: 28,
          child: Text('$installments',
              textAlign: TextAlign.center,
              style: AppTheme.body(16, weight: FontWeight.w700)),
        ),
        _circleBtn(Icons.add, AppTheme.green,
            () => _setInstallments(a, installments + 1)),
      ],
    );
  }

  Widget _circleBtn(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
