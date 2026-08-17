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
import '../../widgets/glass_pill.dart';
import '../paywall_screen.dart';
import '../portal/sync_screen.dart';
import 'batch_list_screen.dart';
import 'list_builder_screen.dart';
import 'lot_detail_screen.dart';
import 'lot_preview_screen.dart';
import 'lot_report.dart';

/// Lists tab (the app's single home for lists): auto-build month-end lists,
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

  /// Auto-build: pack every account still to collect into ready ₹20,000 lists.
  Future<void> _autoBuild() async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          BatchListScreen(accounts: widget.accounts, lots: widget.lots),
    ));
    if (made == true) _reload();
  }

  /// Lists not yet made on the portal (drives the floating Submit pill).
  List<Lot> get _unsubmitted =>
      (_lots ?? const <Lot>[]).where((l) => !l.isSubmitted).toList();

  /// A floating action pill (rounded, shadowed) — shared by "New" and
  /// "Submit on Portal" so they match on the bottom-left stack.
  Widget _pill(String label, IconData icon, VoidCallback onTap,
      {required Color color}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(27),
          boxShadow: const [
            BoxShadow(
                color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 8)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(label,
                style: AppTheme.body(16,
                    weight: FontWeight.w800, color: Colors.white)),
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
      return Lot.relativeDay(DateFormat('dd-MMM-yyyy').parse(day), DateTime.now());
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
                    const Icon(Icons.download_rounded,
                        size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text('Download all (${submittedLots.length})',
                        style: AppTheme.body(12.5,
                            weight: FontWeight.w700, color: Colors.white)),
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
          // "Submit on Portal" — the primary Lists action, as a clear labeled
          // pill stacked just above "New" (not a bare cloud icon up top).
          if (_view == 0 &&
              kEnablePortalSubmit &&
              RemoteConfig.portalSubmit &&
              _unsubmitted.isNotEmpty)
            Positioned(
              left: 20,
              bottom: agentLevelBottom(context) + 66,
              child: _pill(
                'Submit on Portal',
                Icons.cloud_upload_rounded,
                () => _submitAllOnPortal(_unsubmitted),
                color: AppTheme.green,
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
            decoration: BoxDecoration(
              color: active ? AppTheme.black : AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.line),
            ),
            child: Text(label,
                style: AppTheme.body(13.5,
                    weight: FontWeight.w700,
                    color: active ? Colors.white : AppTheme.ink)),
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
      // Auto-build the month's ₹20,000 lists (with a review screen). Making one
      // by hand is the floating "New" pill; submitting is the "Submit on
      // Portal" pill.
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _autoBuild,
            icon: const Icon(Icons.tune_rounded, size: 18),
            label: Text('Auto-build this month\'s lists',
                style: AppTheme.body(13.5, weight: FontWeight.w700)),
            style: TextButton.styleFrom(
                foregroundColor: AppTheme.ink,
                padding: const EdgeInsets.symmetric(horizontal: 6)),
          ),
        ),
      ),
    ];

    if (unsubmitted.isEmpty) {
      items.add(_emptyMsg(
          'No lists to submit',
          'Tap "Auto-build this month\'s lists" or the "New" button to make '
              'this month\'s ₹20,000 lists, then submit them on the portal.'));
    } else {
      for (final entry in Lot.groupByDay(unsubmitted).map(
          (g) => MapEntry(g.day, g.lots))) {
        items.add(_dayHeader(entry.key, entry.value.length));
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
      return _emptyMsg('No downloads yet',
          'Lists you submit on the portal appear here — download each, or a '
              'whole day\'s batch, to submit at the post office.');
    }
    final items = <Widget>[];
    for (final entry in Lot.groupByDay(submitted)) {
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

  Widget _dayHeader(String day, int n) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
        child: Text('${_relDay(day)} · $n list${n == 1 ? '' : 's'}',
            style: AppTheme.body(12.5,
                weight: FontWeight.w700, color: AppTheme.inkMuted)),
      );

  Widget _emptyMsg(String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 20, 32, 60),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.receipt_long_outlined,
                size: 52, color: AppTheme.inkFaint),
            const SizedBox(height: 12),
            Text(title, style: AppTheme.display(18, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(body,
                textAlign: TextAlign.center,
                style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4)),
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
                    child: Text(lot.mode, style: AppTheme.label(AppTheme.green)),
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
                              const Icon(Icons.verified_rounded,
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
                  const Icon(Icons.chevron_right, color: AppTheme.inkFaint),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: AppTheme.divider),
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
