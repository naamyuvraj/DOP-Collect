import 'package:flutter/material.dart';

import '../calc/po_calc.dart';
import '../data/account_repository.dart';
import '../data/app_settings.dart';
import '../data/collection_repository.dart';
import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import 'khata_tab.dart';
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
    this.collections,
  });
  final AccountRepository repo;
  final String accountNumber;

  /// The ledger behind the Khata tab. Optional: the assistant opens this screen
  /// without one, and a missing ledger hides the tab rather than crashing.
  final CollectionRepository? collections;

  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  String _aslaas = '';
  Future<RdAccount?>? _future;
  int? _termYears; // user-adjusted maturity time (± stepper); null = default

  @override
  void initState() {
    super.initState();
    _future = widget.repo.byAccountNumber(widget.accountNumber);
    AppSettings.aslaas().then((v) {
      if (mounted) setState(() => _aslaas = v);
    });
  }

  void _reload() => setState(() {
        _future = widget.repo.byAccountNumber(widget.accountNumber);
      });

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
    if (ok == true && mounted) _reload();
  }

  void _setTerm(int y) => setState(() => _termYears = y.clamp(1, 20));

  /// This account's own ASLAAS, or the legacy agency-wide setting while it's
  /// unknown ('—' if neither exists).
  String _aslaasOf(RdAccount a) {
    final own = a.aslaas?.trim() ?? '';
    if (own.isNotEmpty) return own;
    return _aslaas.isEmpty ? '—' : _aslaas;
  }

  Future<void> _editAslaas(RdAccount a) async {
    final ctrl = TextEditingController(text: a.aslaas ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('ASLAAS number', style: AppTheme.display(17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${a.customerName} · #${a.accountNumber}',
                style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: AppTheme.body(16, weight: FontWeight.w600),
              decoration: const InputDecoration(hintText: 'e.g. 801357'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (value == null) return;
    await widget.repo.setAslaas(a.accountNumber, value);
    if (mounted) _reload();
  }

  /// Maturity value for the chosen term, using the account's locked rate.
  int _maturityFor(RdAccount a, int term) => PoCalc.compute(
        PoScheme.rd,
        amount: a.denominationAmount.toDouble(),
        years: term.toDouble(),
        rate: a.annualRate,
      ).maturity.round();

  @override
  Widget build(BuildContext context) {
    // Two tabs, not a longer scroll: Details answers "what is this account",
    // Khata answers "what has he actually paid me". They're different questions
    // and the agent arrives knowing which one he wants.
    //
    // The Khata tab is dropped entirely when no ledger was passed (the assistant
    // opens this screen without one) rather than shown empty and broken.
    final withKhata = widget.collections != null;
    return DefaultTabController(
      length: withKhata ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Account'),
          bottom: withKhata
              ? TabBar(
                  labelStyle: AppTheme.body(13.5, weight: FontWeight.w800),
                  unselectedLabelStyle: AppTheme.body(13.5),
                  tabs: const [Tab(text: 'DETAILS'), Tab(text: 'KHATA')],
                )
              : null,
        ),
        body: FutureBuilder<RdAccount?>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final a = snap.data!;
            return TabBarView(
              children: [
                _details(a),
                if (withKhata)
                  KhataTab(
                    collections: widget.collections!,
                    accountNumber: a.accountNumber,
                    monthlyAmount: a.denominationAmount,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _details(RdAccount a) {
    final term = _termYears ?? a.termYears;
    return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              _headerCard(a),
              const SizedBox(height: 14),
              if (!a.hasExactDetail) _exactDetailPrompt(a),
              _maturityCard(a, term),
              const SizedBox(height: 12),
              _tileGrid([
                _tile('Monthly RD', inr(a.denominationAmount)),
                _tile('Month Paid', '${a.monthsPaid}'),
                _tile('Short Code', a.serial > 0 ? '${a.serial}' : '—'),
                _tile('Rate', '${a.annualRate}%'),
                _tile('Total Deposited', inr(a.depositedAmount)),
                _tile('Next Due', a.dueDateLabel),
                _tile('Opened On', a.openingDateLabel),
                _tile('Last Deposit', a.lastDepositLabel),
                _tile('Pending', '${a.installmentsToMaturity}'),
                // This account's OWN ASLAAS (the portal keeps a different one
                // per account). Falls back to the old agency-wide setting only
                // until this account's real number is known.
                _tile('ASLAAS', _aslaasOf(a), onTap: () => _editAslaas(a)),
              ]),
              const SizedBox(height: 18),
              _collectionCard(a),
              // Edit Profile / Add Collection / WhatsApp CTAs were all
              // "coming soon" no-ops — hidden until they actually do something,
              // so every tap here isn't teaching him the buttons are decorative.
            ],
    );
  }

  /// Maturity Time with a live ± stepper (left) and the recomputed rate / paid /
  /// maturity figures (right) — like the reference account screen.
  Widget _maturityCard(RdAccount a, int term) {
    final maturity = _maturityFor(a, term);
    final paid = a.denominationAmount * term * 12;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.card(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('MATURITY TIME', style: AppTheme.label(AppTheme.inkMuted)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _stepBtn(Icons.remove, AppTheme.red, () => _setTerm(term - 1)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('$term Year',
                          style: AppTheme.display(18, weight: FontWeight.w800)),
                    ),
                    _stepBtn(Icons.add, AppTheme.green, () => _setTerm(term + 1)),
                  ],
                ),
                if (_termYears != null && _termYears != a.termYears) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => setState(() => _termYears = null),
                    child: Text('Reset to ${a.termYears} yr',
                        style: AppTheme.body(11,
                            weight: FontWeight.w700, color: AppTheme.accent)),
                  ),
                ],
              ],
            ),
          ),
          Container(width: 1, height: 76, color: AppTheme.divider),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv('Rate', '${a.annualRate}%'),
                const SizedBox(height: 6),
                _kv('Paid Amount', inr(paid)),
                const SizedBox(height: 6),
                Text('Maturity Amount', style: AppTheme.label(AppTheme.inkMuted)),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(inr(maturity),
                      style: AppTheme.display(22, weight: FontWeight.w800)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTheme.body(12, color: AppTheme.inkMuted)),
          Text(value, style: AppTheme.body(13.5, weight: FontWeight.w700)),
        ],
      );

  Widget _stepBtn(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

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

  Widget _tile(String label, String value, {VoidCallback? onTap}) {
    final tile = Container(
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
    return onTap == null ? tile : GestureDetector(onTap: onTap, child: tile);
  }

  Widget _collectionCard(RdAccount a) {
    // Collected for this cycle = the portal has moved this account's next due
    // date past the current month. Derived, not a stored flag: the old
    // `status == deposited` mark was never reset, so once an account was put on
    // any list this card claimed "collected" for the rest of its life.
    final deposited = AccountFilter.monthsBehind(a, DateTime.now()) < 0;
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
