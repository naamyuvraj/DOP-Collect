import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/account_repository.dart';
import '../../data/app_settings.dart';
import '../../data/lot_repository.dart';
import '../../models/lot.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../portal/sync_screen.dart';

/// A saved list as a "keying sheet": everything to type into the portal — each
/// account's installments + amount, plus the ASLAAS number — and a Copy button
/// to share the list as text.
class LotDetailScreen extends StatefulWidget {
  const LotDetailScreen({
    super.key,
    required this.lot,
    required this.lots,
    required this.accounts,
  });
  final Lot lot;
  final LotRepository lots;
  final AccountRepository accounts;

  @override
  State<LotDetailScreen> createState() => _LotDetailScreenState();
}

class _LotDetailScreenState extends State<LotDetailScreen> {
  String _aslaas = '';
  late Lot _lot;

  @override
  void initState() {
    super.initState();
    _lot = widget.lot;
    AppSettings.aslaas().then((v) => setState(() => _aslaas = v));
  }

  Lot get lot => _lot;

  /// Remove one account from the list and persist. If it was the last one, the
  /// whole list is offered for deletion.
  Future<void> _removeItem(int index) async {
    final removed = _lot.items[index];
    final remaining = [..._lot.items]..removeAt(index);
    if (remaining.isEmpty) {
      await _delete(message: 'Removing the last account deletes this list.');
      return;
    }
    setState(() => _lot = _lot.copyWith(items: remaining));
    await widget.lots.update(_lot);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Removed ${removed.customerName}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _restore(index, removed),
      ),
    ));
  }

  Future<void> _restore(int index, LotItem item) async {
    final items = [..._lot.items];
    items.insert(index.clamp(0, items.length), item);
    setState(() => _lot = _lot.copyWith(items: items));
    await widget.lots.update(_lot);
  }

  String _asText() {
    final b = StringBuffer()
      ..writeln('DOP Collection List (${lot.mode})')
      ..writeln(lot.dateLabel)
      ..writeln('ASLAAS: ${_aslaas.isEmpty ? "—" : _aslaas}')
      ..writeln('Accounts: ${lot.count} · Installments: ${lot.totalInstallments} '
          '· Total: ${inr(lot.totalAmount)}')
      ..writeln('');
    for (var i = 0; i < lot.items.length; i++) {
      final it = lot.items[i];
      b.writeln('${i + 1}. ${it.customerName}  ${it.accountNumber}  '
          'x${it.installments}  ${inr(it.amount)}');
    }
    return b.toString();
  }

  String _modeCode(String mode) {
    final m = mode.toLowerCase();
    if (m.contains('non')) return 'NDC';
    if (m.contains('cheque') || m == 'dc') return 'DC';
    return 'C';
  }

  /// Open the portal and auto-select this lot's accounts (mode + tick + Save).
  /// Only prepares the list — installments and Pay All stay manual.
  Future<void> _prepareOnPortal() async {
    final accounts = _lot.items.map((e) => e.accountNumber).toSet();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Prepare on portal?', style: AppTheme.display(18)),
        content: Text(
          'Logs in and auto-ticks these ${accounts.length} accounts across the '
          'portal pages (mode: ${_lot.mode}), then Saves the list. You then '
          'enter installments + ASLAAS and tap Pay All yourself.',
          style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SyncScreen(
        repo: widget.accounts,
        prepareAccounts: accounts,
        prepareMode: _modeCode(_lot.mode),
      ),
    ));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _asText()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('List copied — paste into WhatsApp/notes')));
    }
  }

  Future<void> _delete({String? message}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Delete list?', style: AppTheme.display(18)),
        content: Text(
            message ??
                'This removes the saved list. Accounts stay as they are.',
            style: AppTheme.body(13, color: AppTheme.inkMuted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && lot.id != null) {
      await widget.lots.delete(lot.id!);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('List'),
        actions: [
          IconButton(
              tooltip: 'Prepare on portal',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: _prepareOnPortal),
          IconButton(
              tooltip: 'Copy list',
              icon: const Icon(Icons.copy_outlined),
              onPressed: _copy),
          IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline, color: AppTheme.red),
              onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
        children: [
          _summary(),
          const SizedBox(height: 8),
          for (var i = 0; i < lot.items.length; i++) _itemRow(i, lot.items[i]),
        ],
      ),
    );
  }

  Widget _summary() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(inr(lot.totalAmount),
              style: AppTheme.display(30, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('${lot.mode} · ${lot.count} accounts · '
              '${lot.totalInstallments} installments',
              style: AppTheme.body(13, color: AppTheme.inkMuted)),
          const SizedBox(height: 2),
          Text(lot.dateLabel, style: AppTheme.body(12, color: AppTheme.inkFaint)),
          const Divider(height: 20, color: AppTheme.divider),
          Row(
            children: [
              Text('ASLAAS  ', style: AppTheme.label(AppTheme.inkMuted)),
              Text(_aslaas.isEmpty ? 'set in Settings' : _aslaas,
                  style: AppTheme.body(14,
                      weight: FontWeight.w600,
                      color: _aslaas.isEmpty ? AppTheme.red : AppTheme.ink)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemRow(int i, LotItem it) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: AppTheme.card(),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('${i + 1}',
                style: AppTheme.body(13, color: AppTheme.inkFaint)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(it.customerName,
                    style: AppTheme.display(15, weight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('#${it.accountNumber}',
                    style: AppTheme.body(12, color: AppTheme.inkMuted)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('x${it.installments}',
                  style: AppTheme.body(13,
                      weight: FontWeight.w600, color: AppTheme.accent)),
              const SizedBox(height: 2),
              Text(inr(it.amount),
                  style: AppTheme.display(15, weight: FontWeight.w600)),
            ],
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Remove from list',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline,
                color: AppTheme.red, size: 22),
            onPressed: () => _removeItem(i),
          ),
        ],
      ),
    );
  }
}
