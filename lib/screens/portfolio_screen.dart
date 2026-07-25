import 'package:flutter/material.dart';

import '../data/account_repository.dart';
import '../data/app_settings.dart';
import '../models/rd_account.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/push_button.dart';
import 'portal/sync_screen.dart';

/// Per-account profile — a rich, tile-based view of one RD account, mirroring
/// the familiar detail screen. All figures (opening date, total deposit, paid
/// amount, maturity value) are derived from the list sync, so they fill in
/// without any per-account detail crawl.
class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({
    super.key,
    required this.repo,
    required this.accountNumber,
  });
  final AccountRepository repo;
  final String accountNumber;

  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  String _aslaas = '';
  int _version = 0; // bumped after a portal detail fetch to re-read the account

  @override
  void initState() {
    super.initState();
    AppSettings.aslaas().then((v) => setState(() => _aslaas = v));
  }

  /// Pull this account's exact figures (last-deposit date, total deposit,
  /// pending/default installments) from its portal detail page.
  Future<void> _fetchDetail(RdAccount a) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => SyncScreen(
        repo: widget.repo,
        detailAccount: a.accountNumber,
        detailSerial: a.serial,
      ),
    ));
    if (ok == true && mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: FutureBuilder<RdAccount?>(
        key: ValueKey(_version),
        future: widget.repo.byAccountNumber(widget.accountNumber),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final a = snap.data!;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              _headerCard(a),
              const SizedBox(height: 14),
              if (!a.hasExactDetail) _exactDetailPrompt(a),
              _tileGrid([
                _tile('Monthly RD', inr(a.denominationAmount)),
                _tile('Month Paid', '${a.monthsPaid}'),
                _tile('Short Code', a.serial > 0 ? '${a.serial}' : '—'),
                _tile('Maturity Time', '${a.termYears} Year'),
                _tile('Rate', '${a.annualRate}%'),
                _tile('Paid Amount', inr(a.fullTermAmount)),
                _tile('Maturity Amount', inr(a.maturityAmount)),
                _tile('Total Deposited', inr(a.depositedAmount)),
                _tile('Next Due', a.dueDateIso),
                _tile('Opened On', a.openingDateIso),
                _tile('Last Deposit', a.lastDepositIso),
                _tile('Pending', '${a.installmentsToMaturity}'),
                _tile('ASLAAS', _aslaas.isEmpty ? '—' : _aslaas),
              ]),
              const SizedBox(height: 18),
              _collectionCard(a),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: PushButton(
                      color: AppTheme.surface,
                      foreground: AppTheme.ink,
                      onPressed: () => _soon('Edit Profile'),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('Edit Profile'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PushButton(
                      color: AppTheme.black,
                      onPressed: () => _soon('Add Collection'),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add, size: 18),
                          SizedBox(width: 6),
                          Text('Add Collection'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  void _soon(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('$s — coming soon')));

  /// Last-deposit date, exact total deposit and default/pending installments
  /// live only on the portal's detail page, so offer to pull them for this one
  /// account rather than showing a guessed value.
  Widget _exactDetailPrompt(RdAccount a) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: AppTheme.panel(AppTheme.blueSoft, radius: 16),
      child: Row(
        children: [
          const Icon(Icons.cloud_download_outlined,
              color: AppTheme.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Last-deposit date and exact deposit come from the portal.',
              style: AppTheme.body(12.5, color: AppTheme.ink, height: 1.35),
            ),
          ),
          TextButton(
            onPressed: () => _fetchDetail(a),
            child: Text('Fetch',
                style: AppTheme.body(13,
                    weight: FontWeight.w800, color: AppTheme.accent)),
          ),
        ],
      ),
    );
  }

  Widget _headerCard(RdAccount a) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.card(),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.customerName,
                    style: AppTheme.display(20, weight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text('#${a.accountNumber}',
                    style: AppTheme.body(13, color: AppTheme.inkMuted)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _soon('WhatsApp'),
            child: Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                  color: AppTheme.green, shape: BoxShape.circle),
              child: const Icon(Icons.chat_rounded,
                  color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tileGrid(List<Widget> tiles) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 12.0;
      final w = (c.maxWidth - gap * 2) / 3;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }

  Widget _tile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: AppTheme.card(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(AppTheme.inkFaint)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: AppTheme.display(16, weight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _collectionCard(RdAccount a) {
    final deposited = a.status == CollectionStatus.deposited;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('THIS CYCLE', style: AppTheme.label(AppTheme.inkMuted)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _miniStat('Collected',
                    deposited ? inr(a.denominationAmount) : inr(0),
                    AppTheme.green),
              ),
              Container(width: 1, height: 34, color: AppTheme.divider),
              Expanded(
                child: _miniStat('Pending',
                    deposited ? inr(0) : inr(a.denominationAmount),
                    AppTheme.red),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: AppTheme.body(12, color: AppTheme.inkMuted)),
        const SizedBox(height: 4),
        Text(value, style: AppTheme.display(19, weight: FontWeight.w800, color: color)),
      ],
    );
  }
}
