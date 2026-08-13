import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/app_settings.dart';
import '../../models/collection_round.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../util/receipt.dart';

/// One customer on the collect sheet.
///
/// Three ways to take money, in the order he'll reach for them:
///   1. **swipe** — the amount the Daily/Monthly toggle says (one gesture);
///   2. **a suggested amount** — chips built from *this* customer's own figures,
///      never a generic 10/20/50 list;
///   3. **type it** — a box for whatever they actually handed over.
class CollectRow extends StatefulWidget {
  const CollectRow({
    super.key,
    required this.entry,
    required this.daily,
    required this.onCollect,
    required this.onCollectAmount,
    required this.onUndo,
    required this.onSetDaily,
  });

  final RoundEntry entry;

  /// True when the sheet's toggle is on Daily — decides what a swipe takes.
  final bool daily;

  /// Swipe / tick — take the amount for the current mode.
  final VoidCallback onCollect;

  /// Take a specific amount, optionally covering several months.
  final void Function(int amount, int? installments) onCollectAmount;

  final VoidCallback onUndo;

  /// Override this customer's per-visit amount (null clears it back to the
  /// book-wide rule).
  final void Function(int? amount) onSetDaily;

  @override
  State<CollectRow> createState() => _CollectRowState();
}

class _CollectRowState extends State<CollectRow> {
  bool _open = false;
  final _customCtrl = TextEditingController();

  RoundEntry get e => widget.entry;

  /// What a swipe takes right now.
  int get _swipeAmount =>
      widget.daily ? e.progress.dailyNext : e.progress.monthlyNext;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing outstanding — marked, dimmed, but never blocked. He decides.
    final settled = e.group == RoundGroup.settled;

    final row = Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      decoration: AppTheme.card(
          fill: settled ? AppTheme.surfaceSoft : AppTheme.surface),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(children: [_mark(), const SizedBox(width: 12), _body()]),
            ),
          ),
          if (_open) _expanded(),
        ],
      ),
    );

    return Dismissible(
      key: ValueKey('collect-${e.accountNumber}'),
      direction: e.progress.entries.isEmpty
          ? DismissDirection.startToEnd
          : DismissDirection.horizontal,
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          widget.onCollect();
        } else {
          widget.onUndo();
        }
        return false; // the list rebuilds from the ledger; never remove the row
      },
      background: _swipeBg(
          align: Alignment.centerLeft,
          color: AppTheme.green,
          icon: Icons.check_rounded,
          label: inr(_swipeAmount)),
      secondaryBackground: _swipeBg(
          align: Alignment.centerRight,
          color: AppTheme.red,
          icon: Icons.undo_rounded,
          label: 'Undo'),
      child: row,
    );
  }

  Widget _swipeBg({
    required Alignment align,
    required Color color,
    required IconData icon,
    required String label,
  }) =>
      Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        alignment: align,
        decoration: AppTheme.card(fill: color),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(label,
                style: AppTheme.body(14,
                    weight: FontWeight.w800, color: Colors.white)),
          ],
        ),
      );

  /// The tick — also a tap target, for anyone who never learns the swipe.
  Widget _mark() {
    final p = e.progress;
    final done = p.complete;
    return GestureDetector(
      onTap: widget.onCollect,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (p.partial)
              SizedBox(
                width: 38,
                height: 38,
                child: CircularProgressIndicator(
                  value: p.fraction,
                  strokeWidth: 3,
                  backgroundColor: AppTheme.line,
                  valueColor: const AlwaysStoppedAnimation(AppTheme.amber),
                ),
              ),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? AppTheme.green : Colors.transparent,
                border: done
                    ? null
                    : Border.all(
                        color: p.partial ? AppTheme.amber : AppTheme.line,
                        width: 2),
              ),
              child: done
                  ? const Icon(Icons.check_rounded,
                      size: 19, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final p = e.progress;
    final a = e.account;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(a.customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(15, weight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              // The number the swipe will take, so the gesture is never a guess.
              Text(inr(_swipeAmount),
                  style: AppTheme.body(15,
                      weight: FontWeight.w800,
                      color: p.complete ? AppTheme.green : AppTheme.ink)),
            ],
          ),
          const SizedBox(height: 3),
          Text(_subtitle(), style: AppTheme.body(12, color: AppTheme.inkFaint)),
          if (p.partial) ...[
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: p.fraction,
                minHeight: 5,
                backgroundColor: AppTheme.line,
                valueColor: const AlwaysStoppedAnimation(AppTheme.amber),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The one line that has to carry the customer's whole state.
  String _subtitle() {
    final p = e.progress;
    final a = e.account;
    if (e.group == RoundGroup.settled) {
      return p.collected > 0
          ? 'On a list · ${inr(p.collected)} collected'
          : 'Paid ahead — nothing due';
    }
    if (p.complete) {
      final when = p.entries.isEmpty ? '' : ' · ${p.entries.first.timeLabel}';
      final adv = p.advanceMonths > 1 ? ' · ${p.advanceMonths} months' : '';
      return 'Collected$when$adv';
    }
    if (p.partial) {
      // For a daily payer the number that matters is what's left, not the days.
      final settling = widget.daily && p.isSettling ? ' · settle today' : '';
      return '${inr(p.collected)} of ${inr(p.target)} · ${inr(p.remaining)} '
          'left$settling';
    }
    return widget.daily
        ? '${inr(p.dailyAmount)}/day · ${inr(p.target)} due ${a.dueDateLabel}'
        : 'Due ${a.dueDateLabel} · #${_shortAcct(a.accountNumber)}';
  }

  static String _shortAcct(String n) =>
      n.length <= 6 ? n : '…${n.substring(n.length - 4)}';

  /// The other two ways to collect, plus this customer's own settings.
  Widget _expanded() {
    final p = e.progress;
    final a = e.account;

    // Built from THIS account, not a generic list: their daily amount, what
    // settles the month, the full installment, and two months for an advance.
    final suggestions = <(String, int, int?)>[
      ('${inr(p.dailyAmount)} · daily', p.dailyAmount, null),
      if (p.remaining > 0 && p.remaining != p.dailyAmount)
        ('${inr(p.remaining)} · settle', p.remaining, null),
      if (p.target != p.remaining && p.target != p.dailyAmount)
        ('${inr(p.target)} · full', p.target, 1),
      ('${inr(p.target * 2)} · 2 months', p.target * 2, 2),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 18, color: AppTheme.divider),
          Text('COLLECT', style: AppTheme.label(AppTheme.inkFaint)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, amount, inst) in suggestions)
                _chip(
                    label: label,
                    onTap: () => widget.onCollectAmount(amount, inst)),
            ],
          ),
          const SizedBox(height: 12),
          _customBox(),
          const SizedBox(height: 14),
          Text('THIS CUSTOMER\'S DAILY AMOUNT',
              style: AppTheme.label(AppTheme.inkFaint)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  a.hasOwnDailyAmount
                      ? '${inr(a.dailyAmount!)} a visit — set by you'
                      : '${inr(p.dailyAmount)} a visit — '
                          '${inr(p.target)} ÷ month',
                  style: AppTheme.body(12.5, color: AppTheme.inkMuted),
                ),
              ),
              _chip(label: 'Change', onTap: _pickDaily),
              if (a.hasOwnDailyAmount) ...[
                const SizedBox(width: 8),
                _chip(label: 'Reset', onTap: () => widget.onSetDaily(null)),
              ],
            ],
          ),
          if (p.entries.isNotEmpty) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _sendReceipt,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  const Icon(Icons.receipt_long_rounded,
                      size: 18, color: AppTheme.black),
                  const SizedBox(width: 8),
                  Text('Share receipt',
                      style: AppTheme.body(13.5, weight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text('THIS MONTH', style: AppTheme.label(AppTheme.inkFaint)),
            const SizedBox(height: 6),
            for (final c in p.entries.take(6))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${c.dayLabel} · ${c.timeLabel}',
                          style:
                              AppTheme.body(12.5, color: AppTheme.inkMuted)),
                    ),
                    Text(inr(c.amount),
                        style: AppTheme.body(12.5, weight: FontWeight.w700)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Type whatever they actually handed over. The third way to collect, for the
  /// customer who gives ₹70 on a day none of the suggestions match.
  Widget _customBox() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceSoft,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.line),
            ),
            child: TextField(
              controller: _customCtrl,
              keyboardType: TextInputType.number,
              style: AppTheme.body(15, weight: FontWeight.w700),
              cursorColor: AppTheme.accent,
              onChanged: (_) => setState(() {}), // enable/disable the button
              onSubmitted: (_) => _submitCustom(),
              decoration: InputDecoration(
                prefixText: '₹ ',
                prefixStyle: AppTheme.body(15, weight: FontWeight.w700),
                hintText: 'Other amount',
                hintStyle: AppTheme.body(14, color: AppTheme.inkFaint),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _customAmount == null ? null : _submitCustom,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.black,
            minimumSize: const Size(96, 44),
          ),
          child: Text('Collect',
              style: AppTheme.body(14,
                  weight: FontWeight.w800, color: Colors.white)),
        ),
      ],
    );
  }

  /// Digits only — "1,000" typed the way amounts are displayed must not read as
  /// nothing and leave the Collect button dead.
  int? get _customAmount {
    final digits = _customCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    final v = int.tryParse(digits);
    return v != null && v > 0 ? v : null;
  }

  void _submitCustom() {
    final v = _customAmount;
    if (v == null) return;
    widget.onCollectAmount(v, null);
    _customCtrl.clear();
    setState(() {});
  }

  /// Send the customer proof of the latest handover, through the system share
  /// sheet — the app holds no customer phone numbers (the portal doesn't give
  /// them), so he picks the contact in whichever app he uses.
  Future<void> _sendReceipt() async {
    final p = e.progress;
    final last = p.entries.first;
    final text = Receipt.collection(
      customerName: p.account.customerName,
      accountNumber: p.account.accountNumber,
      amount: last.amount,
      at: last.collectedAt,
      collectedThisCycle: p.collected,
      monthlyAmount: p.target,
      agentName: await AppSettings.agentName(),
    );
    await Share.share(text);
  }

  /// Override this one customer's per-visit amount.
  Future<void> _pickDaily() async {
    final p = e.progress;
    final ctrl = TextEditingController(text: '${p.dailyAmount}');
    final value = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Daily amount', style: AppTheme.display(17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${p.account.customerName} pays ${inr(p.target)} a month. '
              'Spread over the month that is ${inr(p.dailyAmount)} a visit — '
              'change it if they give a different amount. The last visit of '
              'the month collects whatever is still left, so it always adds up.',
              style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: AppTheme.body(16, weight: FontWeight.w700),
              decoration: const InputDecoration(prefixText: '₹ '),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(ctrl.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value != null && value > 0) widget.onSetDaily(value);
  }

  Widget _chip({required String label, required VoidCallback onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          height: 38, // comfortable target for an older thumb
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.surfaceSoft,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: AppTheme.line),
          ),
          child: Text(label,
              style: AppTheme.body(13.5, weight: FontWeight.w700)),
        ),
      );
}
