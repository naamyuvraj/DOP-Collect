import 'dart:convert';

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
  const HomeDashboard({super.key, required this.repo});
  final AccountRepository repo;

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard> {
  Future<List<RdAccount>>? _future;
  String _name = '';
  String _photo = '';

  @override
  void initState() {
    super.initState();
    _future = widget.repo.all();
    _loadProfile();
  }

  void _loadProfile() {
    AppSettings.displayName().then((v) {
      if (mounted) setState(() => _name = v);
    });
    AppSettings.profilePhoto().then((v) {
      if (mounted) setState(() => _photo = v);
    });
  }

  Future<void> _viewProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileView()),
    );
    // Name or photo may have changed on the edit screen — refresh both.
    _loadProfile();
  }

  void _reload() => setState(() => _future = widget.repo.all());

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

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              _header(),
              const SizedBox(height: 18),
              const UpdateBanner(),
              FocalCard(
                label: 'Total Portfolio',
                amount: inr(total.amount),
                sublabel: '${all.length} accounts',
              ),
              const SizedBox(height: 6),

              const SizedBox(height: 18),
              _section(
                title: 'First Half',
                tint: const Color(0xFFEFF29A),
                children: [
                  _sum('Pending', AppTheme.amber,
                      AccountFilter.firstHalfPending, s),
                  const SizedBox(height: 10),
                  _sum('Deposited', AppTheme.green,
                      AccountFilter.firstHalfDeposited, s),
                ],
              ),
              _section(
                title: 'Second Half',
                tint: const Color(0xFFB9D6F2),
                children: [
                  _sum('Pending', AppTheme.amber,
                      AccountFilter.secondHalfPending, s),
                  const SizedBox(height: 10),
                  _sum('Deposited', AppTheme.green,
                      AccountFilter.secondHalfDeposited, s),
                ],
              ),
              _section(
                title: 'Attention',
                tint: const Color(0xFFF3B7B7),
                children: [
                  _sum('Defaulters', AppTheme.red,
                      AccountFilter.defaulters, s),
                  const SizedBox(height: 10),
                  _sum('About to Freeze · 6th month', AppTheme.red,
                      AccountFilter.aboutToFreeze, s),
                ],
              ),
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
                  const SizedBox(height: 10),
                  _sum('New Accounts · 3 month', AppTheme.amber,
                      AccountFilter.newAccounts, s),
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
              child: _photo.isEmpty
                  ? Center(
                      child: Text(_initials(),
                          style: AppTheme.display(16,
                              weight: FontWeight.w800, color: Colors.white)),
                    )
                  : Image.memory(base64Decode(_photo),
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
          _iconBtn(Icons.sync_rounded, _openSync),
        ],
      ),
    );
  }

  String _initials() {
    final n = _name.trim();
    if (n.isEmpty) return 'Y';
    return n.split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
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

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
                color: Color(0x14101B12), blurRadius: 16, offset: Offset(0, 6)),
          ],
        ),
        child: Icon(icon, color: AppTheme.ink, size: 22),
      ),
    );
  }
}
