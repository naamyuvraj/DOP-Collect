import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/account_repository.dart';
import '../../services/analytics.dart';
import '../../data/lot_repository.dart';
import '../../models/account_sort.dart';
import '../../models/lot.dart';
import '../../models/lot_packing.dart';
import '../../models/rd_account.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/account_sort_bar.dart';

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

  /// A CASH lot's total must not exceed this (cheque lots have no amount cap).
  static const lotCap = 20000;

  /// Max accounts in one list, any mode (portal rule).
  static const maxAccounts = 50;

  @override
  State<ListBuilderScreen> createState() => _ListBuilderScreenState();
}

class _ListBuilderScreenState extends State<ListBuilderScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  Future<List<RdAccount>>? _future;

  /// null = smart priority (on-time & high-value first); else amount/due sort.
  AccountSort? _sort;

  /// accountNumber -> installments selected (>=1 means included).
  final Map<String, int> _selected = {};
  final Map<String, RdAccount> _byNumber = {};

  /// Payment mode: 'Cash' | 'DOP Cheque' | 'Non DOP Cheque'.
  String _mode = 'Cash';
  bool get _isCheque => _mode.toLowerCase().contains('cheque');

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
      return list;
    });
  }

  /// Apply the chosen order. Null = smart priority (most valuable + most
  /// reliable — paid-ahead / on-time first), shared with the auto-packer.
  List<RdAccount> _applySort(List<RdAccount> list) {
    if (_sort == null) {
      final now = DateTime.now();
      return [...list]..sort((a, b) => LotPacking.priorityCompare(a, b, now));
    }
    return [...list]..sort(_sort!.comparator);
  }

  void _setInstallments(RdAccount a, int value) {
    final denom = a.denominationAmount;
    final current = _selected[a.accountNumber] ?? 0;
    final prospective = _total - denom * current + denom * (value < 0 ? 0 : value);
    final addingNew = current == 0 && value > 0;
    if (addingNew && _selected.length >= ListBuilderScreen.maxAccounts) {
      _warn('A list can hold at most ${ListBuilderScreen.maxAccounts} accounts.');
      return;
    }
    // Amount cap is CASH-only; cheque lists have no rupee limit.
    if (!_isCheque && value > 0 && prospective > ListBuilderScreen.lotCap) {
      _warn('Cash list total can\'t exceed ${inr(ListBuilderScreen.lotCap)}.');
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

  void _warn(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _create() async {
    if (_selected.isEmpty) return;

    // Cheque modes: collect each account's cheque number + bank account first.
    Map<String, ChequeEntry>? cheques;
    if (_isCheque) {
      final rows = _selected.entries
          .map((e) => (
                account: _byNumber[e.key]!,
                installments: e.value,
              ))
          .toList();
      cheques = await Navigator.of(context).push<Map<String, ChequeEntry>>(
        MaterialPageRoute(
          builder: (_) => ChequeEntryScreen(mode: _mode, rows: rows),
        ),
      );
      if (cheques == null || !mounted) return; // cancelled
    }

    // Creating a lot marks every selected account "Deposited" for this cycle —
    // confirm first, since there's no bulk way to undo that mark.
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Create this list?', style: AppTheme.display(17)),
        content: Text(
          '${_selected.length} account${_selected.length == 1 ? '' : 's'} '
          '(${inr(_total)}, $_mode) will be marked deposited for this cycle.',
          style: AppTheme.body(13.5, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (ok != true) return;
    final items = _selected.entries.map((e) {
      final a = _byNumber[e.key]!;
      final chq = cheques?[e.key];
      return LotItem(
        accountNumber: a.accountNumber,
        customerName: a.customerName,
        denomination: a.denominationAmount,
        installments: e.value,
        chequeNumber: chq?.chequeNo,
        bankAccountNumber: chq?.bankAccount,
        // Each account's OWN ASLAAS — the portal holds a different one per
        // account, so this is snapshotted per row, never shared across the list.
        aslaas: a.aslaas,
      );
    }).toList();

    await widget.lots.save(Lot(
      createdAt: DateTime.now(),
      mode: _mode,
      items: items,
    ));
    unawaited(Analytics.track('lot_created',
        {'accounts': items.length, 'amount': _total, 'mode': _mode}));
    // Saving the list is what marks these accounts collected for this cycle —
    // auto-build reads the saved lists back (LotPacking.listedThisCycle) rather
    // than a per-account flag, so the mark expires when the month does.
    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('List created · ${items.length} accounts · '
          '${inr(_total)} · $_mode')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Cash fills toward the ₹20k cap; cheque fills toward the 50-account cap.
    final pct = _isCheque
        ? (_count / ListBuilderScreen.maxAccounts).clamp(0.0, 1.0)
        : (_total / ListBuilderScreen.lotCap).clamp(0.0, 1.0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('New list'),
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
                    _headerStat('Selected',
                        '$_count / ${ListBuilderScreen.maxAccounts}'),
                    _headerStat(
                        'Total',
                        _isCheque
                            ? inr(_total)
                            : '${inr(_total)} / ${inr(ListBuilderScreen.lotCap)}'),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 6,
                    backgroundColor: AppTheme.line,
                    color: pct >= 1.0 ? AppTheme.red : AppTheme.green,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _modeSelector(),
          _searchRow(),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: AccountSortBar(
              value: _sort,
              smartLabel: 'Smart',
              onChanged: (v) => setState(() => _sort = v),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<RdAccount>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = _applySort(snap.data!);
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
              label: Text('Create list ($_count)'),
            ),
    );
  }

  Widget _modeSelector() {
    Widget chip(String label, String mode) {
      final active = _mode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _mode = mode),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? AppTheme.black : AppTheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.line),
            ),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(12.5,
                    weight: FontWeight.w700,
                    color: active ? Colors.white : AppTheme.ink)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 0),
      child: Row(
        children: [
          chip('Cash', 'Cash'),
          chip('DOP Cheque', 'DOP Cheque'),
          chip('Non-DOP', 'Non DOP Cheque'),
        ],
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

/// One account's cheque details for a cheque-mode list.
class ChequeEntry {
  final String chequeNo;
  final String bankAccount; // bank a/c number printed on the cheque
  const ChequeEntry(this.chequeNo, this.bankAccount);
}

/// Collects the cheque number + bank account number for each account in a
/// DOP / Non-DOP cheque list. Returns `accountNumber -> ChequeEntry`, or null
/// if cancelled. Every account must be filled before it can be saved.
class ChequeEntryScreen extends StatefulWidget {
  const ChequeEntryScreen({super.key, required this.mode, required this.rows});
  final String mode;
  final List<({RdAccount account, int installments})> rows;

  @override
  State<ChequeEntryScreen> createState() => _ChequeEntryScreenState();
}

class _ChequeEntryScreenState extends State<ChequeEntryScreen> {
  final Map<String, TextEditingController> _chq = {};
  final Map<String, TextEditingController> _bank = {};

  @override
  void initState() {
    super.initState();
    for (final r in widget.rows) {
      _chq[r.account.accountNumber] = TextEditingController();
      _bank[r.account.accountNumber] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in [..._chq.values, ..._bank.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _done() {
    for (final r in widget.rows) {
      final acc = r.account.accountNumber;
      if (_chq[acc]!.text.trim().isEmpty || _bank[acc]!.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Enter the cheque number and bank account for every account.')));
        return;
      }
    }
    final out = <String, ChequeEntry>{
      for (final r in widget.rows)
        r.account.accountNumber: ChequeEntry(
          _chq[r.account.accountNumber]!.text.trim(),
          _bank[r.account.accountNumber]!.text.trim(),
        ),
    };
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Cheque details · ${widget.mode}')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
        itemCount: widget.rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final r = widget.rows[i];
          final a = r.account;
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: AppTheme.card(radius: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.customerName,
                    style: AppTheme.display(15, weight: FontWeight.w700)),
                Text(
                    '#${a.accountNumber} · ${r.installments} × '
                    '${inr(a.denominationAmount)} = '
                    '${inr(a.denominationAmount * r.installments)}',
                    style: AppTheme.body(12, color: AppTheme.inkMuted)),
                const SizedBox(height: 10),
                _field(_chq[a.accountNumber]!, 'Cheque number',
                    TextInputType.number),
                const SizedBox(height: 8),
                _field(_bank[a.accountNumber]!, 'Bank account number (on cheque)',
                    TextInputType.number),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _done,
        icon: const Icon(Icons.check, size: 20),
        label: const Text('Done'),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, TextInputType kb) {
    return TextField(
      controller: c,
      keyboardType: kb,
      style: AppTheme.body(15, weight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTheme.body(13, color: AppTheme.inkMuted),
        isDense: true,
        filled: true,
        fillColor: AppTheme.surfaceSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}
