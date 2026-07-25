import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/account_repository.dart';
import '../../services/analytics.dart';
import '../../data/lot_repository.dart';
import '../../models/lot.dart';
import '../../models/lot_packing.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/glass_pill.dart';
import '../../widgets/push_button.dart';

/// Lists tab — "Auto List Making". One tap packs every account that needs
/// collecting into as many ₹20,000-capped lots as needed (most-unpaid first),
/// previews them, and saves the whole set to Groups.
class BatchListScreen extends StatefulWidget {
  const BatchListScreen({
    super.key,
    required this.accounts,
    required this.lots,
  });
  final AccountRepository accounts;
  final LotRepository lots;

  static const cap = 20000;

  // Spotlight targets for the guided tour (only one Lists screen is alive at a
  // time, inside the shell's IndexedStack). Steps whose target isn't on screen
  // — e.g. when there's nothing to collect — are skipped by the tour.
  static final summaryKey = GlobalKey();
  static final firstCardKey = GlobalKey();
  static final saveKey = GlobalKey();

  @override
  State<BatchListScreen> createState() => _BatchListScreenState();
}

class _BatchListScreenState extends State<BatchListScreen> {
  List<Lot>? _lots; // null while loading
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await widget.accounts.all();
    final lots = LotPacking.build(all, DateTime.now(), cap: BatchListScreen.cap);
    if (!mounted) return;
    setState(() => _lots = lots);
  }

  /// Remove one account from a generated (unsaved) list. Empties drop the list.
  void _removeMember(int lotIndex, int itemIndex) {
    final lots = _lots;
    if (lots == null) return;
    final lot = lots[lotIndex];
    final removed = lot.items[itemIndex];
    final remaining = [...lot.items]..removeAt(itemIndex);
    setState(() {
      if (remaining.isEmpty) {
        lots.removeAt(lotIndex);
      } else {
        lots[lotIndex] = lot.copyWith(items: remaining);
      }
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Removed ${removed.customerName}'),
    ));
  }

  Future<void> _saveAll() async {
    final lots = _lots;
    if (lots == null || lots.isEmpty) return;
    setState(() => _saving = true);
    for (final lot in lots) {
      await widget.lots.save(lot);
    }
    unawaited(Analytics.track('list_generated', {
      'lists': lots.length,
      'accounts': lots.fold<int>(0, (s, l) => s + l.count),
    }));
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${lots.length} lists saved to Groups.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lots = _lots;
    return Scaffold(
      appBar: AppBar(title: const Text('Lists')),
      body: Stack(
        children: [
          if (lots == null)
            const Center(child: CircularProgressIndicator())
          else if (lots.isEmpty)
            _empty()
          else
            Column(
              children: [
                KeyedSubtree(
                  key: BatchListScreen.summaryKey,
                  child: _summary(
                    lots.length,
                    lots.fold(0, (s, l) => s + l.count),
                    lots.fold(0, (s, l) => s + l.totalAmount),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 110),
                    itemCount: lots.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => i == 0
                        ? KeyedSubtree(
                            key: BatchListScreen.firstCardKey,
                            child: _lotCard(i, lots[i]))
                        : _lotCard(i, lots[i]),
                  ),
                ),
              ],
            ),
          if (lots != null && lots.isNotEmpty)
            Positioned(
              left: 20,
              bottom: agentLevelBottom(context),
              child: GlassPill(
                key: BatchListScreen.saveKey,
                label: _saving ? 'Saving…' : 'Save all to Groups',
                icon: Icons.save_alt_rounded,
                busy: _saving,
                onTap: _saveAll,
              ),
            ),
        ],
      ),
    );
  }

  Widget _summary(int lists, int accounts, int total) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: AppTheme.card(),
      child: Row(
        children: [
          _stat('$lists', 'Lists'),
          _divider(),
          _stat('$accounts', 'Accounts'),
          _divider(),
          _stat(inr(total), 'Total'),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: AppTheme.display(20, weight: FontWeight.w800)),
            ),
            const SizedBox(height: 2),
            Text(label, style: AppTheme.body(11, color: AppTheme.inkMuted)),
          ],
        ),
      );

  Widget _divider() =>
      Container(width: 1, height: 30, color: AppTheme.divider);

  Widget _lotCard(int lotIndex, Lot lot) {
    final number = lotIndex + 1;
    final pct = (lot.totalAmount / BatchListScreen.cap).clamp(0.0, 1.0);
    return Container(
      decoration: AppTheme.card(radius: 18),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          leading: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: AppTheme.panel(AppTheme.greenSoft, radius: 12),
            child: Text('$number',
                style: AppTheme.display(16, weight: FontWeight.w800,
                    color: AppTheme.green)),
          ),
          title: Text('List $number',
              style: AppTheme.display(16, weight: FontWeight.w700)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${lot.count} accounts · ${inr(lot.totalAmount)}',
                    style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 5,
                    backgroundColor: AppTheme.line,
                    color: pct >= 1.0 ? AppTheme.amber : AppTheme.green,
                  ),
                ),
              ],
            ),
          ),
          children: [
            for (var j = 0; j < lot.items.length; j++)
              _memberRow(lotIndex, j, lot.items[j]),
          ],
        ),
      ),
    );
  }

  Widget _memberRow(int lotIndex, int itemIndex, LotItem it) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(it.customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(13.5, weight: FontWeight.w600)),
                Text('#${it.accountNumber}',
                    style: AppTheme.body(11, color: AppTheme.inkFaint)),
              ],
            ),
          ),
          Text(inr(it.amount),
              style: AppTheme.body(13.5, weight: FontWeight.w700)),
          IconButton(
            tooltip: 'Remove from list',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline,
                color: AppTheme.red, size: 20),
            onPressed: () => _removeMember(lotIndex, itemIndex),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 90),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: AppTheme.panel(AppTheme.blueSoft, radius: 24),
              child: const Icon(Icons.playlist_add_check_rounded,
                  color: AppTheme.accent, size: 36),
            ),
            const SizedBox(height: 20),
            Text('Nothing to collect',
                style: AppTheme.display(20, weight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'Every account is already collected or paid ahead. Sync, then '
              'come back to auto-build your ₹20,000 lists.',
              textAlign: TextAlign.center,
              style: AppTheme.body(14, color: AppTheme.inkMuted, height: 1.5),
            ),
            const SizedBox(height: 18),
            PushButton(
              color: AppTheme.surface,
              foreground: AppTheme.ink,
              onPressed: _load,
              child: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}
