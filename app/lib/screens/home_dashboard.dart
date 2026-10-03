import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../data/account_repository.dart';
import '../models/rd_account.dart';
import '../models/summaries.dart';
import '../services/cloud_sync.dart';
import '../services/remote_config.dart';
import '../theme/app_theme.dart';
import '../widgets/press.dart';
import '../data/app_settings.dart';
import '../util/format.dart';
import '../widgets/section_panel.dart';
import '../widgets/summary_card.dart';
import '../widgets/update_banner.dart';
import 'account_list_screen.dart';
import 'onboarding_login.dart';
import 'paywall_screen.dart';
import 'portal/sync_screen.dart';
import 'profile_view.dart';

/// Home dashboard in the soft-UI style: a yellow hero (total value) over a
/// mint canvas, then clean white floating summary cards.
class HomeDashboard extends StatefulWidget {
  const HomeDashboard(
      {super.key, required this.repo, this.onOpenLists, this.onSynced});
  final AccountRepository repo;

  /// Jump to the Lists tab (auto-list builder) — wired by the shell so the
  /// "Make today's list" CTA lands on the right screen.
  final VoidCallback? onOpenLists;

  /// A Sync finished here. The shell refreshes the other tabs — the first-run
  /// CTA lives on this screen, so most syncs start from here.
  final VoidCallback? onSynced;

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard> {
  Future<List<RdAccount>>? _future;
  String _name = '';
  Uint8List? _photoBytes; // decoded once, not on every frame (P4)
  Fortnight _half = Fortnight.first; // segmented First/Second-half toggle
  bool _balanceHidden = true; // balance hero masked by default (privacy)

  @override
  void initState() {
    super.initState();
    // Matured accounts too. `repo.all()` is live-only, so without this the
    // Maturity card counted 7 while its own list showed 10 — the card and the
    // screen it opens disagreed, which is worse than either number alone.
    // Every other bucket filters them out anyway: a closed account is not
    // behind, not due, and not new.
    _future = Future.wait([
      widget.repo.all(),
      widget.repo.maturedSince(maturedFrom(DateTime.now())),
    ]).then((r) => [...r[0], ...r[1]]);
    _loadProfile();
  }

  int _lastSyncMs = 0;

  void _loadProfile() {
    AppSettings.lastSyncMs().then((v) {
      if (mounted) setState(() => _lastSyncMs = v);
    });
    AppSettings.agentName().then((v) {
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
      // Matured accounts too. `repo.all()` is live-only, so without this the
      // Maturity card counted 7 while its own list showed 10 — the card and the
      // screen it opens disagreed, which is worse than either number alone.
      // Every other bucket filters them out anyway: a closed account is not
      // behind, not due, and not new.
      _future = Future.wait([
        widget.repo.all(),
        widget.repo.maturedSince(maturedFrom(DateTime.now())),
      ]).then((r) => [...r[0], ...r[1]]);
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

  bool _cloudSyncing = false;

  /// "Sync" means a different thing on each platform, because the platforms can
  /// do different things.
  ///
  ///   phone   drive the DOP portal, walk the listing, rewrite the book — then
  ///           upload it.
  ///   browser pull down whatever the phone uploaded. A browser tab cannot
  ///           reach the portal at all (see [SyncScreen]), so this is not a
  ///           reduced version of the phone's sync; it is the whole of what a
  ///           desktop can do, and it is the only way this app gets data.
  ///
  /// It used to push [SyncScreen] on both, which on web meant a WebView that
  /// renders nothing: the button opened a blank page.
  Future<void> _openSync() async {
    if (kIsWeb) return _cloudSync();
    if (!await ensureDopLogin(context) || !mounted) return;
    if (!await gatePremium(context) || !mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SyncScreen(repo: widget.repo)),
    );
    if (ok == true) {
      _reload();
      widget.onSynced?.call();
      // The portal has just rewritten the book, so this is the moment the
      // agent's other device is most out of date. Fire-and-forget: a failed
      // upload must never make a successful portal sync look like it failed,
      // and the next run picks up exactly where this one stopped.
      unawaited(CloudSync.run());
    }
  }

  Future<void> _cloudSync() async {
    if (_cloudSyncing) return;
    setState(() => _cloudSyncing = true);
    final r = await CloudSync.run();
    if (!mounted) return;
    setState(() => _cloudSyncing = false);

    // Say what happened, including "nothing" — a Sync button that flashes and
    // leaves the screen identical is indistinguishable from one that is broken.
    final text = !r.ok
        ? r.message
        : r.changedAnything
            ? 'Synced — ${r.pulled} in, ${r.pushed} out.'
            : 'Already up to date.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 3),
    ));
    if (r.pulled > 0) {
      _reload();
      widget.onSynced?.call();
    }
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

          if (MediaQuery.of(context).size.width >= kDesktopBreakpoint) {
            return _desktopBody(all, s, total);
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              _header(),
              const SizedBox(height: 18),
              const UpdateBanner(),
              _announcementBanner(),
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
                children: [
                  _sum('Defaulters', AppTheme.red, AccountFilter.defaulters, s),
                  const SizedBox(height: 10),
                  // "of which" is not decoration. Freezing soon is every
                  // account 6+ months behind, so it is a strict SUBSET of
                  // Defaulters — the same customers, counted again. Two plain
                  // totals stacked in one panel read as two separate problems
                  // and invite adding them together.
                  _sum('of which freezing soon (6 mo+)', AppTheme.red,
                      AccountFilter.aboutToFreeze, s,
                      rank: 1),
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
                children: [
                  _sum('Maturity', AppTheme.green, AccountFilter.maturity, s,
                      amount: false),
                  const SizedBox(height: 10),
                  _sum('Advanced Paid', AppTheme.accent,
                      AccountFilter.advancedPaid, s,
                      amount: false, rank: 1),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// The dashboard, laid out for a screen instead of a thumb.
  ///
  /// The handset build is one column because a phone has one column. Given a
  /// desktop it would just be that same column with empty space either side —
  /// which is what "the phone app in a browser" means, and it wastes the one
  /// thing the bigger screen actually offers: seeing the whole book at once
  /// instead of scrolling to it.
  ///
  /// So the figures are arranged by how they are USED, not by how they fit:
  ///
  ///   row 1  the three numbers he opens the app to check — what the book is
  ///          worth, what is still to collect, and what is overdue. Above the
  ///          fold, always, no scrolling.
  ///   row 2  the two working panels side by side. Collection is this cycle's
  ///          job; Portfolio is the book's health. They answer different
  ///          questions, so stacking them made one of them scroll away.
  ///
  /// These are stat tiles, deliberately, not charts. Every figure here is a
  /// single magnitude with no series and no time axis — a chart would add
  /// furniture (axes, grid, legend) around one number and make it slower to
  /// read, not faster.
  Widget _desktopBody(
      List<RdAccount> all, Stat Function(AccountFilter) s, Stat total) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 40),
      children: [
        _desktopHeader(),
        const SizedBox(height: 16),
        const UpdateBanner(),
        _announcementBanner(),
        _lastSyncedLine(),
        const SizedBox(height: 4),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The hero keeps its privacy toggle — the whole point of it is
              // that the agent can open this in front of a customer.
              Expanded(
                flex: 5,
                child: FocalCard(
                  label: 'Monthly Book',
                  amount: inr(total.amount),
                  sublabel: '${all.length} accounts',
                  hidden: _balanceHidden,
                  onToggleVisibility: () =>
                      setState(() => _balanceHidden = !_balanceHidden),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 3,
                child: _kpiTile('To Collect', AppTheme.amber,
                    AccountFilter.toCollect, s),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 3,
                child: _kpiTile('Defaulters', AppTheme.red,
                    AccountFilter.defaulters, s),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _collectionPanel(s),
                  _section(
                    title: 'Attention',
                    children: [
                      _sum('Defaulters', AppTheme.red,
                          AccountFilter.defaulters, s),
                      const SizedBox(height: 10),
                      // A strict SUBSET of the row above — the same customers,
                      // counted again. Ranked so the two do not read as two
                      // separate problems worth adding together.
                      _sum('of which freezing soon (6 mo+)', AppTheme.red,
                          AccountFilter.aboutToFreeze, s,
                          rank: 1),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section(
                    title: 'Portfolio',
                    children: [
                      _sum('Maturity', AppTheme.green, AccountFilter.maturity,
                          s,
                          amount: false),
                      const SizedBox(height: 10),
                      _sum('Advanced Paid', AppTheme.accent,
                          AccountFilter.advancedPaid, s,
                          amount: false, rank: 1),
                    ],
                  ),
                  _section(
                    title: 'Growth',
                    children: [_newAccountsCard(s)],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// One headline figure, for the row above the fold.
  ///
  /// The status colour is a dot beside a written label, never the label itself:
  /// "Defaulters" has to survive being read by someone who cannot tell the red
  /// dot from the amber one, and by a printout.
  Widget _kpiTile(
      String title, Color color, AccountFilter f, Stat Function(AccountFilter) s) {
    final st = s(f);
    return PressFace(
      onTap: () => _openFilter(f),
      decoration: (face) => AppTheme.card(offset: face),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(13,
                        weight: FontWeight.w700, color: AppTheme.inkMuted)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(inr(st.amount), style: AppTheme.display(30)),
          ),
          const SizedBox(height: 2),
          Text('${st.count} accounts',
              style: AppTheme.body(12, color: AppTheme.inkFaint)),
        ],
      ),
    );
  }

  /// The desktop header.
  ///
  /// No avatar and no "Namaste" here. That block is a phone convention — it
  /// exists on a handset because there is no persistent chrome to hold the
  /// account — and on a desktop it is now duplicated by the rail's profile
  /// row, two paces to the left. A dashboard's header should say which page
  /// you are on and offer the page's one action; the greeting is neither.
  Widget _desktopHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Dashboard', style: AppTheme.display(21)),
                const SizedBox(height: 2),
                Text(
                  _name.isEmpty ? 'Collection portfolio' : _name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body(12.5, color: AppTheme.inkFaint),
                ),
              ],
            ),
          ),
          _syncPill(),
        ],
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
              decoration:
                  BoxDecoration(color: AppTheme.black, shape: BoxShape.circle),
              child: _photoBytes == null
                  ? Center(
                      child: Text(_initials(),
                          style: AppTheme.display(16,
                              weight: FontWeight.w800,
                              color: AppTheme.onAccent)),
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
    return PressFace(
      onTap: _cloudSyncing ? null : _openSync,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // Pressable, so it stands off the page like every other button — and
      // sinks like one.
      decoration: (face) =>
          AppTheme.card(fill: AppTheme.black, radius: 22, offset: face),
      child: Row(
        children: [
          Icon(Icons.sync_rounded, color: AppTheme.onAccent, size: 20),
          const SizedBox(width: 6),
          Text(_cloudSyncing ? 'Syncing…' : 'Sync',
              style: AppTheme.body(14,
                  weight: FontWeight.w700, color: AppTheme.onAccent)),
        ],
      ),
    );
  }

  String _initials() {
    final parts = _name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (parts.isEmpty) return 'Y';
    return parts.take(2).map((w) => w[0]).join().toUpperCase();
  }

  /// "Last synced" trust line — turns amber once the data is over a day old.
  /// Remote announcement from the admin dashboard (app_config). Hidden unless
  /// enabled with non-empty text.
  Widget _announcementBanner() {
    final a = RemoteConfig.announcement;
    if (!a.enabled || a.text.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppTheme.focal,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.campaign_rounded, size: 20, color: AppTheme.onFocal),
          const SizedBox(width: 10),
          Expanded(
            child: Text(a.text.trim(),
                style: AppTheme.body(13,
                    weight: FontWeight.w600,
                    color: AppTheme.onFocal,
                    height: 1.35)),
          ),
        ],
      ),
    );
  }

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
          Icon(Icons.cloud_sync_rounded, size: 48, color: AppTheme.inkFaint),
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
          PressFace(
            onTap: _openSync,
            height: 50,
            alignment: Alignment.center,
            // It was a flat charcoal slab — the one button on an empty screen,
            // and the only one in the app with nothing to push into.
            rest: AppTheme.buttonFace,
            decoration: (face) =>
                AppTheme.card(fill: AppTheme.black, radius: 14, offset: face),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.sync_rounded, color: AppTheme.onAccent, size: 20),
                const SizedBox(width: 8),
                Text('Sync Collection',
                    style: AppTheme.body(15,
                        weight: FontWeight.w700, color: AppTheme.onAccent)),
              ],
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
      child: SectionPanel(
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
            _sum('Deposited', AppTheme.green, deposited, s, rank: 1),
          ],
        ),
      ),
    );
  }

  Widget _halfToggle() {
    Widget seg(String label, Fortnight half) {
      final active = _half == half;
      return PressFace(
        onTap: () => setState(() => _half = half),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        // Only the chosen segment is a raised block; the other is bare text on
        // the track, so it recoils rather than sinking.
        rest: active ? AppTheme.faceOffsetPressed : 0,
        pressedFace: 0,
        decoration: (face) => active
            ? AppTheme.card(fill: AppTheme.black, radius: 20, offset: face)
            : const BoxDecoration(),
        child: Text(label,
            style: AppTheme.body(12,
                weight: FontWeight.w700,
                color: active ? AppTheme.onAccent : AppTheme.inkMuted)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.6),
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
        child: Text(text, style: AppTheme.display(17, weight: FontWeight.w800)),
      );

  Widget _section({
    required String title,
    required List<Widget> children,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SectionPanel(
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
      // The 1/2/3-month window used to sit here as a dropdown. A control
      // inside a summary tile makes the tile two things at once — a figure to
      // read and a form to operate — and it was the only card on the page you
      // could touch without opening it. It now lives on the list this card
      // opens, where changing the window and seeing the accounts it lets in
      // are the same glance. The card just reports the current window, which
      // defaults to one month.
      onView: () => _openFilter(AccountFilter.newAccounts),
    );
  }

  Widget _sum(String title, Color color, AccountFilter f,
      Stat Function(AccountFilter) s,
      {bool amount = true, int rank = 0}) {
    final st = s(f);
    return SummaryCard(
      title: title,
      statusColor: color,
      rank: rank,
      count: '${st.count}',
      amount: amount ? inr(st.amount) : null,
      onView: () => _openFilter(f),
    );
  }
}
