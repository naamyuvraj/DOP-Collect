import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/account_repository.dart';
import '../../data/app_settings.dart';
import '../../data/credentials.dart';
import '../../data/lot_repository.dart';
import '../../models/lot.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/glass_pill.dart';
import 'list_builder_screen.dart';
import 'lot_detail_screen.dart';
import 'lot_report.dart';

/// Groups tab: create a lot (manual) and view saved lots. Each saved lot is a
/// DOP-style "list" that can be opened, printed, shared, or sent on WhatsApp as
/// a Recurring Deposit Installment Report.
class SavedListsScreen extends StatefulWidget {
  const SavedListsScreen({super.key, required this.accounts, required this.lots});
  final AccountRepository accounts;
  final LotRepository lots;

  @override
  State<SavedListsScreen> createState() => _SavedListsScreenState();
}

class _SavedListsScreenState extends State<SavedListsScreen> {
  Future<List<Lot>>? _future;
  String _agentName = '';
  String _agentId = '';
  String _aslaas = '';

  @override
  void initState() {
    super.initState();
    _reload();
    AppSettings.agentName().then((v) => _agentName = v);
    AppSettings.aslaas().then((v) => _aslaas = v);
    Credentials.load().then((c) => _agentId = c.agentId);
  }

  void _reload() => setState(() => _future = widget.lots.all());

  Future<void> _newList() async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          ListBuilderScreen(accounts: widget.accounts, lots: widget.lots),
    ));
    if (made == true) _reload();
  }

  Future<void> _print(Lot lot) async {
    final bytes = await buildLotReportPdf(lot,
        agentName: _agentName, agentId: _agentId, aslaas: _aslaas);
    await Printing.layoutPdf(
        onLayout: (_) async => bytes, name: '${lotReference(lot)}.pdf');
  }

  Future<void> _share(Lot lot) async {
    final bytes = await buildLotReportPdf(lot,
        agentName: _agentName, agentId: _agentId, aslaas: _aslaas);
    await Printing.sharePdf(bytes: bytes, filename: '${lotReference(lot)}.pdf');
  }

  Future<void> _whatsapp(Lot lot) async {
    await Share.share(lotReportText(lot, aslaas: _aslaas),
        subject: 'RD List ${lotReference(lot)}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
      // Positioned in a Stack (not floatingActionButton) so its bottom edge
      // lines up EXACTLY with the shell's AI Agent button.
      body: Stack(
        children: [
          FutureBuilder<List<Lot>>(
            future: _future,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final lots = snap.data!;
              if (lots.isEmpty) {
                return _empty();
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
                itemCount: lots.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _lotCard(lots[i]),
              );
            },
          ),
          Positioned(
            left: 20,
            bottom: agentLevelBottom(context),
            child: GlassPill(
              label: 'Create Lot',
              icon: Icons.add,
              onTap: _newList,
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.receipt_long_outlined,
              size: 56, color: AppTheme.inkFaint),
          const SizedBox(height: 12),
          Text('No lots yet',
              style: AppTheme.display(18, weight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('Tap "Create Lot" to group accounts (max ₹20,000).',
              style: AppTheme.body(13, color: AppTheme.inkMuted)),
        ],
      ),
    );
  }

  Widget _lotCard(Lot lot) {
    return Container(
      decoration: AppTheme.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LotDetailScreen(
                    lot: lot, lots: widget.lots, accounts: widget.accounts),
              ));
              _reload();
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: AppTheme.panel(AppTheme.greenSoft, radius: 8),
                    child: Text(lot.mode, style: AppTheme.label(AppTheme.green)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(inr(lot.totalAmount),
                            style:
                                AppTheme.display(20, weight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          '${lotReference(lot)} · ${lot.count} accts · '
                          '${lot.dateLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.body(12, color: AppTheme.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: AppTheme.inkFaint),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: AppTheme.divider),
          Row(
            children: [
              _action('Print', Icons.print_rounded, AppTheme.accent,
                  () => _print(lot)),
              _vline(),
              _action('Share', Icons.ios_share_rounded, AppTheme.accent,
                  () => _share(lot)),
              _vline(),
              _action('WhatsApp', Icons.chat_rounded, AppTheme.green,
                  () => _whatsapp(lot)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _vline() => Container(width: 1, height: 24, color: AppTheme.divider);

  Widget _action(String label, IconData icon, Color color, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 7),
              Text(label,
                  style: AppTheme.body(13,
                      weight: FontWeight.w600, color: AppTheme.ink)),
            ],
          ),
        ),
      ),
    );
  }
}
