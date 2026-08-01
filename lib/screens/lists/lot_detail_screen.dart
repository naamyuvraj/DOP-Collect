import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/account_repository.dart';
import '../../data/app_settings.dart';
import '../../data/credentials.dart';
import '../../data/lot_repository.dart';
import '../../models/lot.dart';
import '../../services/analytics.dart';
import '../../services/remote_config.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/push_button.dart';
import '../portal/sync_screen.dart';
import 'lot_preview_screen.dart';
import 'lot_report.dart';

/// Feature gate for the full portal-submission automation (auto-key installments
/// + rebate/default + per-record Save, then capture the Pay-All reference).
/// The app NEVER taps Pay All — the agent reviews the amounts on the portal and
/// pays himself, so money always moves by a human hand. ENABLED at the user's
/// direction; the FIRST real use must be a supervised 1-account cash list to
/// confirm the live portal behaves as the captured markup did. See
/// PORTAL_WORKFLOW.md. Set back to `false` to fall back to prepare-only.
const bool kEnablePortalSubmit = true;

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
  String _agentName = '';
  String _agentId = '';
  late Lot _lot;

  @override
  void initState() {
    super.initState();
    _lot = widget.lot;
    AppSettings.aslaas().then((v) {
      if (mounted) setState(() => _aslaas = v);
    });
    AppSettings.agentName().then((v) => _agentName = v);
    Credentials.load().then((c) => _agentId = c.agentId);
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

  /// Submit on the portal: log in, tick this lot's accounts (mode + Save), then
  /// auto-key each account's installments (+ rebate/default). The app STOPS
  /// before Pay All — you review and tap "Pay All Saved Installments" on the
  /// portal yourself, and it captures the reference back onto the list.
  Future<void> _prepareOnPortal() async {
    final accounts = _lot.items.map((e) => e.accountNumber).toSet();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(kEnablePortalSubmit ? 'Submit on portal?' : 'Prepare on portal?',
            style: AppTheme.display(18)),
        content: Text(
          kEnablePortalSubmit
              ? 'Logs in, ticks these ${accounts.length} accounts (mode: '
                  '${_lot.mode}), Saves, and keys their installments — NO payment '
                  'happens. You then review and tap "Pay All Saved Installments" '
                  'on the portal yourself; the app captures the reference.'
              : 'Logs in and ticks these ${accounts.length} accounts (mode: '
                  '${_lot.mode}), then Saves the list. You then enter installments '
                  'and tap Pay All on the portal yourself.',
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
    final ref = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => SyncScreen(
        repo: widget.accounts,
        prepareAccounts: accounts,
        prepareMode: _modeCode(_lot.mode),
        // Gated: full auto-submit stays off until the supervised on-device test.
        submitLot: kEnablePortalSubmit ? _lot : null,
      ),
    ));
    if (ref == null || ref.isEmpty || !mounted) return;
    setState(() =>
        _lot = _lot.copyWith(referenceNumber: ref, submittedAt: DateTime.now()));
    await widget.lots.update(_lot);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submitted — reference $ref saved to this list.')));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _asText()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('List copied — paste into WhatsApp/notes')));
    }
  }

  /// See the list's PDF first (full-screen, pinch-to-zoom) and download/share it
  /// from there. Named by the real E-Banking reference once submitted.
  Future<void> _preview() async {
    unawaited(Analytics.track('list_preview', {'submitted': _lot.isSubmitted}));
    final ref = _lot.referenceNumber ?? lotReference(_lot);
    final bytes = await buildLotReportPdf(_lot,
        agentName: _agentName, agentId: _agentId, aslaas: _aslaas);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LotPreviewScreen(
        title: _lot.isSubmitted ? 'List ${_lot.referenceNumber}' : 'List preview',
        bytes: bytes,
        filename: '$ref.pdf',
      ),
    ));
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
      bottomNavigationBar: _bottomBar(),
    );
  }

  /// Primary actions, as clear labelled buttons (not bare app-bar icons):
  /// see/download the PDF, and — until it's submitted — Submit on Portal.
  Widget _bottomBar() {
    // Gated by both the compile-time flag AND the remote kill switch, so the
    // portal automation can be disabled for everyone from the dashboard.
    final canSubmit =
        kEnablePortalSubmit && RemoteConfig.portalSubmit && !lot.isSubmitted;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: PushButton(
                onPressed: _preview,
                color: AppTheme.surface,
                foreground: AppTheme.ink,
                radius: 14,
                expand: false, // else it balloons to full height in a bottom bar
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.visibility_rounded, size: 18, color: AppTheme.ink),
                    SizedBox(width: 8),
                    Flexible(
                        child: Text('Preview & Download',
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            ),
            if (canSubmit) ...[
              const SizedBox(width: 10),
              Expanded(
                child: PushButton(
                  onPressed: _prepareOnPortal,
                  color: AppTheme.green,
                  foreground: Colors.white,
                  radius: 14,
                  expand: false,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_upload_rounded,
                          size: 18, color: Colors.white),
                      SizedBox(width: 8),
                      Flexible(
                          child: Text('Submit on Portal',
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
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
          const SizedBox(height: 8),
          // Submission state: the real portal reference once paid, else a clear
          // "not submitted" so the local L… id is never mistaken for it.
          Row(
            children: [
              Icon(lot.isSubmitted ? Icons.verified_rounded : Icons.info_outline,
                  size: 16,
                  color: lot.isSubmitted ? AppTheme.green : AppTheme.inkMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  lot.isSubmitted
                      ? 'Submitted · Ref ${lot.referenceNumber}'
                      : 'Not submitted yet (local list only)',
                  style: AppTheme.body(12.5,
                      weight: FontWeight.w700,
                      color:
                          lot.isSubmitted ? AppTheme.green : AppTheme.inkMuted),
                ),
              ),
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
