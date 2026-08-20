import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../data/account_repository.dart';
import '../../data/app_settings.dart';
import '../../data/credentials.dart';
import '../../data/lot_repository.dart';
import '../../models/lot.dart';
import '../../services/analytics.dart';
import '../../services/remote_config.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/action_pill.dart';
import '../paywall_screen.dart';
import '../portal/sync_screen.dart';
import 'list_builder_screen.dart';
import 'lot_detail_screen.dart';
import 'lot_preview_screen.dart';
import 'lot_report.dart';

/// Lists tab (the app's single home for lists): build month-end lists,
/// make one by hand, and manage saved lists — open, print, share on WhatsApp,
/// or prepare on the DOP portal. Each list is a Recurring Deposit Installment
/// schedule for the post office.
class SavedListsScreen extends StatefulWidget {
  const SavedListsScreen({
    super.key,
    required this.accounts,
    required this.lots,
  });
  final AccountRepository accounts;
  final LotRepository lots;
  // No CollectionRepository on purpose: lists are built from the portal book
  // and edited by hand. Nothing on this tab reads the field ledger.

  @override
  State<SavedListsScreen> createState() => _SavedListsScreenState();
}

class _SavedListsScreenState extends State<SavedListsScreen> {
  List<Lot>? _lots; // null while first load is in flight
  String _agentName = '';
  String _agentId = '';
  String _aslaas = '';
  int _view = 0; // 0 = Lists (not yet on portal), 1 = Downloads (submitted)

  /// Which day's batch is showing, per view; null = all of them. Both tabs
  /// already grouped by day, but on a busy week that is a long scroll to reach
  /// the four lists made this morning past the three from yesterday. Kept per
  /// view because the two tabs hold different days — a batch can be submitted
  /// on a different day from the one it was built on.
  String? _listsDay;
  String? _downloadsDay;
  Set<int> _downloaded = {}; // lot ids already downloaded

  @override
  void initState() {
    super.initState();
    _reload();
    AppSettings.agentName().then((v) => _agentName = v);
    AppSettings.aslaas().then((v) => _aslaas = v);
    Credentials.load().then((c) => _agentId = c.agentId);
    AppSettings.downloadedLotIds().then((s) {
      if (mounted) setState(() => _downloaded = s);
    });
  }

  Future<void> _markDownloaded(Lot lot) async {
    unawaited(Analytics.track('list_download', {'submitted': lot.isSubmitted}));
    if (lot.id == null) return;
    final next = {..._downloaded, lot.id!};
    await AppSettings.setDownloadedLotIds(next);
    if (mounted) setState(() => _downloaded = next);
  }

  /// The reference to name a file/share by: the real E-Banking reference once
  /// the list is submitted, else the local L… id for a draft.
  String _ref(Lot lot) => lot.referenceNumber ?? lotReference(lot);

  /// Open one list's report in a full-screen, zoomable preview. Downloading
  /// from there marks it downloaded. Same screen serves drafts and submitted
  /// lists — the only difference is the mark-downloaded callback.
  Future<void> _preview(Lot lot, {bool markOnDownload = false}) async {
    final bytes = await buildLotReportPdf(lot,
        agentName: _agentName, agentId: _agentId, aslaas: _aslaas);
    if (!mounted) return;
    unawaited(Analytics.track('list_preview', {'submitted': lot.isSubmitted}));
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LotPreviewScreen(
        title: lot.isSubmitted ? 'List ${lot.referenceNumber}' : 'List preview',
        bytes: bytes,
        filename: '${_ref(lot)}.pdf',
        onDownloaded: markOnDownload ? () => _markDownloaded(lot) : null,
      ),
    ));
  }

  // Held in state (not a FutureBuilder) so the floating "Submit on Portal" pill
  // in the outer Stack can see how many lists are still unsubmitted. Keeps the
  // old list visible during a refresh instead of flashing a spinner.
  void _reload() {
    widget.lots.all().then((lots) {
      if (mounted) setState(() => _lots = lots);
    });
  }

  /// Manual list builder (pick accounts by hand).
  Future<void> _newList() async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          ListBuilderScreen(accounts: widget.accounts, lots: widget.lots),
    ));
    if (made == true) _reload();
  }

  /// A floating action pill (rounded, shadowed) — shared by "New" and
  /// "Submit on Portal" so they match on the bottom-left stack.
  Widget _pill(String label, IconData icon, VoidCallback onTap,
      {required Color color}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        // Same hard face as every other button. This used to paint its own
        // blurred drop shadow — the glass language the palette replaced — so
        // it read as soft and flat beside the pressables around it.
        decoration:
            AppTheme.card(fill: color, radius: 27, offset: AppTheme.buttonFace),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppTheme.onAccent, size: 22),
            const SizedBox(width: 8),
            Text(label,
                style: AppTheme.body(16,
                    weight: FontWeight.w800, color: AppTheme.onAccent)),
          ],
        ),
      ),
    );
  }

  /// Preview + download a whole batch of lists as ONE bundled PDF (each list on
  /// its own page) — to submit together at the post office.
  Future<void> _printBundle(List<Lot> lots, String day) async {
    if (lots.isEmpty) return;
    final bytes = await buildBundlePdf(lots,
        agentName: _agentName, agentId: _agentId, aslaas: _aslaas);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LotPreviewScreen(
        title: '${lots.length} lists · $day',
        bytes: bytes,
        filename: 'RD-lists-$day-${lots.length}.pdf',
      ),
    ));
  }

  Future<void> _submitAllOnPortal(List<Lot> unsubmitted) async {
    if (!await gatePremium(context) || !mounted) return;
    final total = unsubmitted.fold<int>(0, (s, l) => s + l.totalNetAmount);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Submit ${unsubmitted.length} lists?',
            style: AppTheme.display(17)),
        content: Text(
          'Logs in once and works through all ${unsubmitted.length} lists on the '
          'portal (up to ${inr(total)} total). You confirm each list\'s payment '
          'separately — nothing is paid without your tap.',
          style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Start')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => SyncScreen(
        repo: widget.accounts,
        batchLots: unsubmitted,
        lotStore: widget.lots,
      ),
    ));
    if (done == true && mounted) _reload();
  }

  /// Batch header: the day + a "Download all (N)" button that bundles that day's
  /// lists into one PDF.
  /// "Today" / "Yesterday" / the date itself. `day` arrives as the already
  /// formatted `dd-MMM-yyyy` group key, so parse it back rather than plumb a
  /// DateTime through every caller.
  static String _relDay(String day) {
    try {
      return Lot.relativeDay(
          DateFormat('dd-MMM-yyyy').parse(day), DateTime.now());
    } catch (_) {
      return day; // unparseable — show it as-is rather than lose the header
    }
  }

  Widget _batchHeader(String day, List<Lot> dayLots) {
    // Only submitted lists (with a real portal reference) can be handed in at
    // the counter — so "Download all" bundles ONLY those, and hides if none.
    final submittedLots = dayLots.where((l) => l.isSubmitted).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_relDay(day),
                    style: AppTheme.display(15, weight: FontWeight.w800)),
                Text(
                    '${dayLots.length} list${dayLots.length == 1 ? '' : 's'}'
                    '${submittedLots.isNotEmpty ? ' · ${submittedLots.length} submitted' : ''}',
                    style: AppTheme.body(11.5, color: AppTheme.inkMuted)),
              ],
            ),
          ),
          if (submittedLots.isNotEmpty)
            GestureDetector(
              onTap: () => _printBundle(submittedLots, day),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: AppTheme.panel(AppTheme.black, radius: 10),
                child: Row(
                  children: [
                    Icon(Icons.download_rounded,
                        size: 16, color: AppTheme.onAccent),
                    const SizedBox(width: 6),
                    Text('Download all (${submittedLots.length})',
                        style: AppTheme.body(12.5,
                            weight: FontWeight.w700, color: AppTheme.onAccent)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Share the actual PDF (WhatsApp / Drive / Files). The old text-only
  /// "WhatsApp" action did the same job less well, so it was folded into this.
  /// Named by the real E-Banking reference once submitted (not the local id).
  Future<void> _share(Lot lot) async {
    unawaited(Analytics.track('list_share', {'submitted': lot.isSubmitted}));
    final bytes = await buildLotReportPdf(lot,
        agentName: _agentName, agentId: _agentId, aslaas: _aslaas);
    await Printing.sharePdf(bytes: bytes, filename: '${_ref(lot)}.pdf');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lists'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
      body: Stack(
        children: [
          Builder(builder: (context) {
            final lots = _lots;
            if (lots == null) {
              return const Center(child: CircularProgressIndicator());
            }
            // Not-yet-on-portal lists live in "Lists"; submitted ones move to
            // "Downloads" (ready to hand in at the counter).
            final unsubmitted = lots.where((l) => !l.isSubmitted).toList();
            final submitted = lots.where((l) => l.isSubmitted).toList();
            return Column(
              children: [
                _viewTabs(unsubmitted.length, submitted.length),
                Expanded(
                  child: _view == 0
                      ? _listsView(unsubmitted)
                      : _downloadsView(submitted),
                ),
              ],
            );
          }),
          // "New" (make a list by hand) — floating pill, bottom-left, on the
          // same level as the AI assistant button. Lists view only.
          if (_view == 0)
            Positioned(
              left: 20,
              bottom: agentLevelBottom(context),
              child: _pill(
                'New',
                Icons.add_rounded,
                _newList,
                color: AppTheme.black,
              ),
            ),
        ],
      ),
    );
  }

  /// Segmented tabs — replaces the old "+ New" spot.
  Widget _viewTabs(int nLists, int nDownloads) {
    Widget tab(String label, int i) {
      final active = _view == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _view = i),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: AppTheme.card(
                fill: active ? AppTheme.black : AppTheme.surface,
                radius: 12,
                offset: active ? AppTheme.faceOffsetPressed : 0),
            child: Text(label,
                style: AppTheme.body(13.5,
                    weight: FontWeight.w700,
                    color: active ? AppTheme.onAccent : AppTheme.ink)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 12, 11, 8),
      child: Row(children: [
        tab('Lists ($nLists)', 0),
        tab('Downloads ($nDownloads)', 1),
      ]),
    );
  }

  // --- Lists view (not yet on portal) --------------------------------------

  Widget _listsView(List<Lot> unsubmitted) {
    final items = <Widget>[
      _batchFilter(
          unsubmitted, _listsDay, (v) => setState(() => _listsDay = v)),
    ];

    if (unsubmitted.isEmpty) {
      items.add(_emptyMsg(
          'No lists to submit',
          'Tap "New" to make this month\'s ₹20,000 lists, then submit them on '
              'the portal.'));
    } else {
      for (final entry in Lot.groupByDay(_onlyDay(unsubmitted, _listsDay))
          .map((g) => MapEntry(g.day, g.lots))) {
        items.add(_dayHeader(entry.key, entry.value));
        for (final lot in entry.value) {
          items.add(Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _lotCard(lot, downloads: false)));
        }
      }
    }
    return ListView(
      // Extra bottom room so the last card clears the stacked New + Submit pills.
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 196),
      children: items,
    );
  }

  // --- Downloads view (submitted / made on the portal) ---------------------

  Widget _downloadsView(List<Lot> submitted) {
    if (submitted.isEmpty) {
      return _emptyMsg(
          'No downloads yet',
          'Lists you submit on the portal appear here — download each, or a '
              'whole day\'s batch, to submit at the post office.');
    }
    final items = <Widget>[
      _batchFilter(
          submitted, _downloadsDay, (v) => setState(() => _downloadsDay = v)),
    ];
    for (final entry in Lot.groupByDay(_onlyDay(submitted, _downloadsDay))) {
      items.add(_batchHeader(entry.day, entry.lots)); // day + "Download all"
      for (final lot in entry.lots) {
        items.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _lotCard(lot, downloads: true)));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 130),
      children: items,
    );
  }

  /// Pick one day's batch, or all of them. Only shown when there is more than
  /// one day to choose between — a single-batch tab needs no filter.
  Widget _batchFilter(
      List<Lot> lots, String? selected, ValueChanged<String?> onChanged) {
    final days = <String>[];
    for (final g in Lot.groupByDay(lots)) {
      days.add(g.day);
    }
    if (days.length < 2) return const SizedBox.shrink();
    // Matches the fallback in _onlyDay: a stale selection reads as "All".
    final active = days.contains(selected) ? selected : null;
    final now = DateTime.now();
    String label(String day) {
      final lot = lots.firstWhere((l) => l.filedDayLabel == day);
      return Lot.relativeDay(lot.filedAt, now);
    }

    Widget chip(String text, bool active, VoidCallback onTap) =>
        GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: AppTheme.card(
                fill: active ? AppTheme.black : AppTheme.surface,
                radius: 20,
                offset: active ? AppTheme.faceOffsetPressed : 0),
            child: Text(text,
                style: AppTheme.body(12.5,
                    weight: FontWeight.w700,
                    color: active ? AppTheme.onAccent : AppTheme.ink)),
          ),
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Row(
        children: [
          chip('All (${lots.length})', active == null, () => onChanged(null)),
          for (final day in days) ...[
            const SizedBox(width: 8),
            chip(
                '${label(day)} '
                '(${lots.where((l) => l.filedDayLabel == day).length})',
                active == day,
                () => onChanged(day)),
          ],
        ],
      ),
    );
  }

  /// [lots] narrowed to the chosen batch.
  ///
  /// A day that no longer has any lists falls back to showing everything
  /// rather than an empty screen: submitting a batch moves it from Lists to
  /// Downloads, so the day you were filtered to can vanish under you.
  List<Lot> _onlyDay(List<Lot> lots, String? day) {
    if (day == null) return lots;
    final kept = lots.where((l) => l.filedDayLabel == day).toList();
    return kept.isEmpty ? lots : kept;
  }

  /// "Today · 4 lists · ₹61,000" with the day's submit action on the same
  /// line.
  ///
  /// The total belongs here because the batch is what gets carried to the post
  /// office, and its figure was only ever visible by adding up the cards. And
  /// submitting is an action ON this batch, so it reads better as a link at
  /// the end of the batch's own line than as a floating pill that hovered over
  /// the last card and hid it.
  Widget _dayHeader(String day, List<Lot> lots) {
    final total = lots.fold(0, (s, l) => s + l.totalNetAmount);
    final n = lots.length;
    final canSubmit = kEnablePortalSubmit &&
        RemoteConfig.portalSubmit &&
        // !isSubmitted (referenceNumber == null), the same test lot_detail
        // uses. submittedAt is a different field and a lot can carry one
        // without the other.
        lots.any((l) => !l.isSubmitted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
      child: Row(
        children: [
          // Expanded, not Flexible: the label takes the whole line so the
          // submit link is pushed out to the right edge instead of sitting
          // immediately after the text and floating mid-row.
          Expanded(
            child: Text(
                '${_relDay(day)} · $n list${n == 1 ? '' : 's'} · ${inr(total)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(12.5,
                    weight: FontWeight.w700, color: AppTheme.inkMuted)),
          ),
          if (canSubmit) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => _submitAllOnPortal(
                  lots.where((l) => l.submittedAt == null).toList()),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Submit on Portal',
                      style: AppTheme.body(12.5,
                              weight: FontWeight.w800,
                              color: AppTheme.green,
                              spacing: 10)
                          .copyWith(
                              decoration: TextDecoration.underline,
                              decorationColor: AppTheme.green)),
                  const SizedBox(width: 2),
                  Icon(Icons.arrow_forward_rounded,
                      size: 14, color: AppTheme.green),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyMsg(String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 20, 32, 60),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 52, color: AppTheme.inkFaint),
            const SizedBox(height: 12),
            Text(title, style: AppTheme.display(18, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(body,
                textAlign: TextAlign.center,
                style:
                    AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4)),
          ],
        ),
      ),
    );
  }

  Widget _lotCard(Lot lot, {required bool downloads}) {
    final isDownloaded = lot.id != null && _downloaded.contains(lot.id);
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
                    child:
                        Text(lot.mode, style: AppTheme.label(AppTheme.green)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(inr(lot.totalNetAmount),
                            style:
                                AppTheme.display(20, weight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (lot.isSubmitted) ...[
                              Icon(Icons.verified_rounded,
                                  size: 13, color: AppTheme.green),
                              const SizedBox(width: 3),
                            ],
                            Flexible(
                              child: Text(
                                // Real E-Banking ref once submitted, else the
                                // local L… id.
                                // The day is already the group header, so the
                                // TIME is what separates two batches filed on
                                // the same day. It also stops this line running
                                // long enough to ellipsise away the reference —
                                // the one handle the counter clerk asks for.
                                '${lot.referenceNumber ?? lotReference(lot)} · '
                                '${lot.count} accts · ${lot.filedTimeLabel}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.body(12,
                                    color: lot.isSubmitted
                                        ? AppTheme.green
                                        : AppTheme.inkMuted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: AppTheme.inkFaint),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: AppTheme.divider),
          Row(
            children: [
              if (downloads)
                _action(
                    isDownloaded ? 'Downloaded' : 'Download',
                    isDownloaded
                        ? Icons.check_circle_rounded
                        : Icons.download_rounded,
                    isDownloaded ? AppTheme.green : AppTheme.accent,
                    () => _preview(lot, markOnDownload: true))
              else
                _action('Preview', Icons.visibility_rounded, AppTheme.accent,
                    () => _preview(lot)),
              _vline(),
              _action('Share', Icons.ios_share_rounded, AppTheme.accent,
                  () => _share(lot)),
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
          padding: const EdgeInsets.symmetric(vertical: 15),
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
