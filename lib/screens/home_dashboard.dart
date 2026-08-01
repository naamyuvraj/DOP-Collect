import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/account_repository.dart';
import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../theme/app_theme.dart';
import '../data/app_settings.dart';
import '../util/format.dart';
import '../widgets/glass_panel.dart';
import '../widgets/summary_card.dart';
import '../widgets/update_banner.dart';
import 'account_list_screen.dart';
import 'portal/sync_screen.dart';
import 'profile_view.dart';

/// Home dashboard in the soft-UI style: a yellow hero (total value) over a
/// mint canvas, then clean white floating summary cards.
class HomeDashboard extends StatefulWidget {
  const HomeDashboard({super.key, required this.repo, this.onOpenLists});
  final AccountRepository repo;

  /// Jump to the Lists tab (auto-list builder) — wired by the shell so the
  /// "Make today's list" CTA lands on the right screen.
  final VoidCallback? onOpenLists;

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard> {
  Future<List<RdAccount>>? _future;
  String _name = '';
  Uint8List? _photoBytes; // decoded once, not on every frame (P4)
  int _newMonths = AccountFilter.newAccountMonths;
  Fortnight _half = Fortnight.first; // segmented First/Second-half toggle
  bool _balanceHidden = true; // balance hero masked by default (privacy)

  @override
  void initState() {
    super.initState();
    _future = widget.repo.all();
    _loadProfile();
  }

  int _lastSyncMs = 0;

  void _loadProfile() {
    AppSettings.lastSyncMs().then((v) {
      if (mounted) setState(() => _lastSyncMs = v);
    });
    AppSettings.displayName().then((v) {
      if (mounted) setState(() => _name = v);
    });
    AppSettings.profilePhoto().then((v) {
      if (!mounted) return;
      setState(() => _photoBytes = v.isEmpty ? null : base64Decode(v));
    });
  }

  Future<void> _viewProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileView()),
    );
    // Name or photo may have changed on the edit screen — refresh both.
    _loadProfile();
  }

  void _reload() {
    // Block body so the closure returns void, not the Future (setState rejects
    // a returned Future).
    setState(() {
      _future = widget.repo.all();
    });
    AppSettings.lastSyncMs().then((v) {
      if (mounted) setState(() => _lastSyncMs = v);
    });
  }

  void _openFilter(AccountFilter filter) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => AccountListScreen(repo: widget.repo, filter: filter),
        ))
        .then((_) => _reload());
  }

  Future<void> _openSync() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SyncScreen(repo: widget.repo)),
    );
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: FutureBuilder<List<RdAccount>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final now = DateTime.now();
          final all = snap.data!;
          Stat s(AccountFilter f) => f.statOf(all, now);
          final total = AccountFilter.all.statOf(all, now);

          if (all.isEmpty) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                _header(),
                const SizedBox(height: 18),
                const UpdateBanner(),
                _emptyState(),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              _header(),
              const SizedBox(height: 18),
              const UpdateBanner(),
              _lastSyncedLine(),
              // Balance hero — hidden by default for privacy; the eye reveals it.
              FocalCard(
                label: 'Monthly Book',
                amount: inr(total.amount),
                sublabel: '${all.length} accounts',
                hidden: _balanceHidden,
                onToggleVisibility: () =>
                    setState(() => _balanceHidden = !_balanceHidden),
              ),
              const SizedBox(height: 18),
              // First + Second half folded into one card with a segmented
              // toggle, instead of two near-identical ~200px sections.
              _collectionPanel(s),
              _section(
                title: 'Attention',
                tint: const Color(0xFFF3B7B7),
                children: [
                  _sum('Defaulters', AppTheme.red,
                      AccountFilter.defaulters, s),
                  const SizedBox(height: 10),
                  _sum('Freezing soon (6 mo)', AppTheme.red,
                      AccountFilter.aboutToFreeze, s),
                ],
              ),
              // New Accounts — always visible.
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _newAccountsCard(s),
              ),
              // Portfolio — visible by default (no "See more" gate).
              _section(
                title: 'Portfolio',
                tint: const Color(0xFFCFC1F2),
                children: [
                  _sum('Maturity', AppTheme.green, AccountFilter.maturity, s,
                      amount: false),
                  const SizedBox(height: 10),
                  _sum('Advanced Paid', AppTheme.accent,
                      AccountFilter.advancedPaid, s,
                      amount: false),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header() {
    final title = _name.isEmpty ? 'Collection Portfolio' : _name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: _viewProfile,
            child: Container(
              width: 44,
              height: 44,
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(
                  color: AppTheme.black, shape: BoxShape.circle),
              child: _photoBytes == null
                  ? Center(
                      child: Text(_initials(),
                          style: AppTheme.display(16,
                              weight: FontWeight.w800, color: Colors.white)),
                    )
                  : Image.memory(_photoBytes!,
                      fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: _viewProfile,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Namaste 🙏',
                      style: AppTheme.body(13, color: AppTheme.inkMuted)),
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.display(17, weight: FontWeight.w800)),
                ],
              ),
            ),
          ),
          _syncPill(),
        ],
      ),
    );
  }

  /// Labelled sync control — the most consequential action on Home shouldn't be
  /// an unlabelled circle.
  Widget _syncPill() {
    return GestureDetector(
      onTap: _openSync,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
          color: AppTheme.black,
          borderRadius: BorderRadius.all(Radius.circular(22)),
        ),
        child: Row(
          children: [
            const Icon(Icons.sync_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            Text('Sync',
                style: AppTheme.body(14,
                    weight: FontWeight.w700, color: Colors.white)),
          ],
        ),
      ),
    );
  }

  String _initials() {
    final parts = _name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (parts.isEmpty) return 'Y';
    return parts.take(2).map((w) => w[0]).join().toUpperCase();
  }

  /// "Last synced" trust line — turns amber once the data is over a day old.
  Widget _lastSyncedLine() {
    if (_lastSyncMs == 0) return const SizedBox(height: 6);
    final when = DateTime.fromMillisecondsSinceEpoch(_lastSyncMs);
    final ago = DateTime.now().difference(when);
    final stale = ago.inHours >= 24;
    final text = ago.inMinutes < 1
        ? 'just now'
        : ago.inMinutes < 60
            ? '${ago.inMinutes} min ago'
            : ago.inHours < 24
                ? '${ago.inHours} hr ago'
                : '${ago.inDays} day${ago.inDays == 1 ? '' : 's'} ago';
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded,
              size: 14, color: stale ? AppTheme.amber : AppTheme.inkFaint),
          const SizedBox(width: 6),
          Text('Last synced: $text',
              style: AppTheme.body(12.5,
                  weight: FontWeight.w600,
                  color: stale ? AppTheme.amber : AppTheme.inkMuted)),
        ],
      ),
    );
  }

  /// Honest first-run state: no fake customers, just a clear Sync call-to-action.
  Widget _emptyState() {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 26),
      decoration: AppTheme.card(),
      child: Column(
        children: [
          const Icon(Icons.cloud_sync_rounded,
              size: 48, color: AppTheme.inkFaint),
          const SizedBox(height: 14),
          Text('No accounts yet',
              style: AppTheme.display(18, weight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Sync your collection from the DOP portal to bring in all your RD '
            'accounts. It takes about a minute.',
            textAlign: TextAlign.center,
            style: AppTheme.body(13.5, color: AppTheme.inkMuted, height: 1.4),
          ),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: _openSync,
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppTheme.black,
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.sync_rounded,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text('Sync Collection',
                      style: AppTheme.body(15,
                          weight: FontWeight.w700, color: Colors.white)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One "Collection" panel with a First/Second-half segmented toggle.
  Widget _collectionPanel(Stat Function(AccountFilter) s) {
    final first = _half == Fortnight.first;
    final pending = first
        ? AccountFilter.firstHalfPending
        : AccountFilter.secondHalfPending;
    final deposited = first
        ? AccountFilter.firstHalfDeposited
        : AccountFilter.secondHalfDeposited;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GlassPanel(
        tint: const Color(0xFFCDE6C6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _glassHeading('Collection'),
                const Spacer(),
                _halfToggle(),
              ],
            ),
            const SizedBox(height: 12),
            _sum('Pending', AppTheme.amber, pending, s),
            const SizedBox(height: 10),
            _sum('Deposited', AppTheme.green, deposited, s),
          ],
        ),
      ),
    );
  }

  Widget _halfToggle() {
    Widget seg(String label, Fortnight half) {
      final active = _half == half;
      return GestureDetector(
        onTap: () => setState(() => _half = half),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? AppTheme.black : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label,
              style: AppTheme.body(12,
                  weight: FontWeight.w700,
                  color: active ? Colors.white : AppTheme.inkMuted)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(children: [
        seg('1st half', Fortnight.first),
        seg('2nd half', Fortnight.second),
      ]),
    );
  }

  Widget _glassHeading(String text) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(text,
            style: AppTheme.display(17, weight: FontWeight.w800)),
      );

  Widget _section({
    required String title,
    required Color tint,
    required List<Widget> children,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: GlassPanel(
          tint: tint,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _glassHeading(title),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );

  /// New Accounts card with an inline 1/2/3-month window dropdown (default 1).
  Widget _newAccountsCard(Stat Function(AccountFilter) s) {
    final st = s(AccountFilter.newAccounts);
    return SummaryCard(
      title: 'New Accounts',
      statusColor: AppTheme.amber,
      count: '${st.count}',
      amount: inr(st.amount),
      onView: () => _openFilter(AccountFilter.newAccounts),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: AppTheme.panel(AppTheme.surfaceSoft, radius: 10),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: _newMonths,
            isDense: true,
            style: AppTheme.body(13, weight: FontWeight.w700),
            items: const [
              DropdownMenuItem(value: 1, child: Text('1 mo')),
              DropdownMenuItem(value: 2, child: Text('2 mo')),
              DropdownMenuItem(value: 3, child: Text('3 mo')),
            ],
            onChanged: (v) async {
              if (v == null) return;
              AccountFilter.newAccountMonths = v;
              await AppSettings.setNewAccountMonths(v);
              if (mounted) setState(() => _newMonths = v);
            },
          ),
        ),
      ),
    );
  }

  Widget _sum(String title, Color color, AccountFilter f,
      Stat Function(AccountFilter) s,
      {bool amount = true}) {
    final st = s(f);
    return SummaryCard(
      title: title,
      statusColor: color,
      count: '${st.count}',
      amount: amount ? inr(st.amount) : null,
      onView: () => _openFilter(f),
    );
  }

}
