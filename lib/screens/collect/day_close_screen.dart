import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/app_settings.dart';
import '../../data/collection_repository.dart';
import '../../models/collection.dart';
import '../../models/rd_account.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../util/receipt.dart';

/// End of the round: count the cash against what the app recorded.
///
/// The one moment in the day when a mistake is still cheap to find. He is
/// carrying real notes, and the app's total is only right if every handover was
/// actually recorded — so this screen states the expected figure, takes what he
/// actually counted, and when the two disagree puts the day's entries in front
/// of him with an undo on each, rather than just reporting a mismatch and
/// leaving him to hunt for it.
class DayCloseScreen extends StatefulWidget {
  const DayCloseScreen({
    super.key,
    required this.collections,
    required this.accounts,
    required this.day,
  });

  final CollectionRepository collections;
  final List<RdAccount> accounts;
  final DateTime day;

  @override
  State<DayCloseScreen> createState() => _DayCloseScreenState();
}

class _DayCloseScreenState extends State<DayCloseScreen> {
  List<Collection>? _entries;
  final _countedCtrl = TextEditingController();
  int? _counted;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _countedCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await widget.collections.forDay(widget.day);
    if (!mounted) return;
    setState(() => _entries = rows);
  }

  Map<String, String> get _names => {
        for (final a in widget.accounts) a.accountNumber: a.customerName
      };

  int get _expected =>
      (_entries ?? const []).fold(0, (s, c) => s + c.amount);

  /// counted − recorded. Negative means cash is missing; positive means a
  /// handover never made it into the app.
  int? get _difference => _counted == null ? null : _counted! - _expected;

  Future<void> _undo(Collection c) async {
    if (c.id == null) return;
    await widget.collections.remove(c.id!);
    _changed = true;
    await _load();
  }

  Future<void> _share() async {
    final text = Receipt.daySummary(
      day: widget.day,
      entries: _entries ?? const [],
      namesByAccount: _names,
      counted: _counted,
    );
    await Share.share(text);
  }

  Future<void> _close() async {
    // Null when he closed without counting — stored as such, so the sheet
    // reports "closed", never "counted".
    await AppSettings.setDayClosed(widget.day,
        counted: _counted, recorded: _expected);
    if (!mounted) return;
    Navigator.of(context).pop(_changed);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Count your cash'),
        actions: [
          IconButton(
            tooltip: 'Send the day\'s summary',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: entries == null || entries.isEmpty ? null : _share,
          ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
              children: [
                _expectedCard(entries),
                const SizedBox(height: 14),
                _countCard(),
                if (_difference != null && _difference != 0) ...[
                  const SizedBox(height: 14),
                  _mismatchHelp(),
                ],
                const SizedBox(height: 20),
                Text('TODAY\'S COLLECTIONS  ${entries.length}',
                    style: AppTheme.label(AppTheme.inkMuted)),
                const SizedBox(height: 6),
                if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('Nothing recorded today.',
                        textAlign: TextAlign.center,
                        style: AppTheme.body(14, color: AppTheme.inkMuted)),
                  ),
                for (final c in entries) _entryRow(c),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: entries == null ? null : _close,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.black,
              minimumSize: const Size.fromHeight(52),
            ),
            // Say which it is. Closing without a count is allowed — he may just
            // want the day marked — but it must not look like a reconciliation.
            child: Text(
                _counted == null ? 'Close without counting' : 'Close the day',
                style: AppTheme.body(15,
                    weight: FontWeight.w800, color: Colors.white)),
          ),
        ),
      ),
    );
  }

  Widget _expectedCard(List<Collection> entries) => Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: AppTheme.card(fill: AppTheme.focal),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('THE APP RECORDED', style: AppTheme.label(AppTheme.ink)),
            const SizedBox(height: 6),
            Text(inr(_expected),
                style: AppTheme.display(32, weight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
                '${entries.length} collections · '
                '${DateTime(widget.day.year, widget.day.month, widget.day.day) == DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day) ? 'today' : 'that day'}',
                style: AppTheme.body(13, color: AppTheme.inkMuted)),
          ],
        ),
      );

  Widget _countCard() {
    final diff = _difference;
    final (Color tint, String message) = switch (diff) {
      null => (AppTheme.inkFaint, 'Count the notes in your bag and type the total.'),
      0 => (AppTheme.green, 'Tallies exactly. Nothing missing.'),
      final d when d < 0 => (
          AppTheme.red,
          'You are ${inr(-d)} short of what the app recorded.'
        ),
      final d => (
          AppTheme.amber,
          '${inr(d)} more than recorded — a collection was probably not entered.'
        ),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WHAT YOU COUNTED', style: AppTheme.label(AppTheme.inkFaint)),
          const SizedBox(height: 8),
          TextField(
            controller: _countedCtrl,
            keyboardType: TextInputType.number,
            style: AppTheme.display(24, weight: FontWeight.w800),
            cursorColor: AppTheme.accent,
            decoration: InputDecoration(
              prefixText: '₹ ',
              prefixStyle: AppTheme.display(24, weight: FontWeight.w800),
              hintText: '0',
              hintStyle: AppTheme.display(24,
                  weight: FontWeight.w800, color: AppTheme.line),
              border: InputBorder.none,
              isDense: true,
            ),
            // Strip anything that isn't a digit before parsing. Typing
            // "18,400" the way the totals are displayed used to parse as null,
            // which left the difference unchecked AND recorded the count as
            // matching — a reconciliation screen silently claiming agreement it
            // never tested is the worst failure it could have.
            onChanged: (v) => setState(() {
              final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
              _counted = digits.isEmpty ? null : int.tryParse(digits);
            }),
          ),
          const Divider(height: 20, color: AppTheme.divider),
          Row(
            children: [
              Container(width: 8, height: 8,
                  decoration:
                      BoxDecoration(color: tint, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message,
                    style: AppTheme.body(13, color: AppTheme.inkMuted,
                        height: 1.35)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A mismatch is a prompt to look, not a verdict — the fix is almost always
  /// in the list below, so say what to look for.
  Widget _mismatchHelp() {
    final short = (_difference ?? 0) < 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: AppTheme.card(
          fill: short ? AppTheme.redSoft : AppTheme.amberSoft),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(short ? Icons.search_rounded : Icons.add_circle_outline_rounded,
              size: 20, color: short ? AppTheme.red : AppTheme.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              short
                  ? 'Check the list below. If a customer is there who did not '
                      'actually pay you, undo that entry.'
                  : 'Someone paid you without being recorded. Go back to the '
                      'round and swipe them in — then count again.',
              style: AppTheme.body(12.5, color: AppTheme.ink, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryRow(Collection c) {
    final name = _names[c.accountNumber] ?? c.accountNumber;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: AppTheme.card(radius: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(14.5, weight: FontWeight.w700)),
                Text(c.timeLabel,
                    style: AppTheme.body(11.5, color: AppTheme.inkFaint)),
              ],
            ),
          ),
          Text(inr(c.amount),
              style: AppTheme.body(14.5, weight: FontWeight.w800)),
          IconButton(
            tooltip: 'Undo this entry',
            icon: const Icon(Icons.undo_rounded,
                size: 19, color: AppTheme.inkFaint),
            onPressed: () => _undo(c),
          ),
        ],
      ),
    );
  }
}
