import 'package:flutter/material.dart';

import '../services/remote_config.dart';
import '../services/subscription.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/push_button.dart';
import 'privacy_screen.dart';

/// If payments are on AND this agent's plan has expired, show the paywall and
/// block the action. Returns true when the action may proceed. A no-op (returns
/// true) while payments are off, so premium features stay open until launch.
Future<bool> gatePremium(BuildContext context) async {
  if (!Subscription.blocked) return true;
  await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PaywallScreen(hardGate: true)));
  return !Subscription.blocked; // true only if they subscribed just now
}

/// Plans + subscribe. Shown from Settings ("Subscription") or as a hard gate
/// when access has ended.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key, this.hardGate = false});

  /// A hard gate (access ended) can't be dismissed casually.
  final bool hardGate;

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  SubStatus? _s;
  String? _busyPlan; // which plan's button is mid-purchase (per-card, not global)
  bool _restoring = false;

  bool get _checkoutReady => Subscription.opener != null;
  bool get _active => _s?.status == 'active' || _s?.status == 'trial';

  @override
  void initState() {
    super.initState();
    _s = Subscription.current;
    Subscription.refresh().then((v) {
      if (mounted) setState(() => _s = v ?? _s);
    });
  }

  Future<void> _choose(Plan plan) async {
    if (!_checkoutReady) {
      _snack('Subscriptions open soon — checkout isn\'t enabled in this build.');
      return;
    }
    setState(() => _busyPlan = plan.code);
    try {
      final ok = await Subscription.purchase(plan.code);
      if (!mounted) return;
      if (ok) {
        _snack('Payment successful — you\'re all set!');
        Navigator.of(context).maybePop();
      } else if (Subscription.lastError != null) {
        _showError(Subscription.lastError!);
      } else {
        _snack('Payment cancelled.');
      }
    } on CheckoutUnavailable {
      if (mounted) _snack('Subscriptions open soon.');
    } catch (_) {
      if (mounted) _snack('Couldn\'t start payment. Try again.');
    } finally {
      if (mounted) setState(() => _busyPlan = null);
    }
  }

  /// Safety net: re-pull entitlement from the server. Covers the case where a
  /// payment went through (webhook activated it) but the app's cached status is
  /// stale — so a paid user is never trapped on the paywall.
  Future<void> _restore() async {
    setState(() => _restoring = true);
    final v = await Subscription.refresh();
    if (!mounted) return;
    setState(() {
      _s = v ?? _s;
      _restoring = false;
    });
    if (!Subscription.blocked && _active) {
      _snack('You\'re active — thanks!');
      Navigator.of(context).maybePop();
    } else {
      _snack('No active subscription found yet. If you just paid, wait a moment '
          'and try again.');
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  void _showError(String msg) => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Payment didn\'t go through', style: AppTheme.display(17)),
          content: Text(
            '$msg\n\nIf money was deducted, tap "I\'ve already paid" — it may '
            'take a moment to confirm.',
            style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final plans = (s?.plans ?? const <Plan>[]).where((p) => !p.isFree).toList()
      ..sort((a, b) => a.priceInr.compareTo(b.priceInr));
    // Best value = lowest effective per-month price.
    Plan? best;
    double bestPerMonth = double.infinity;
    for (final p in plans) {
      final pm = p.durationDays > 0 ? p.priceInr / (p.durationDays / 30) : 0;
      if (pm < bestPerMonth) {
        bestPerMonth = pm.toDouble();
        best = p;
      }
    }
    final monthly = plans
        .where((p) => (p.durationDays - 30).abs() <= 5)
        .fold<double?>(null, (m, p) => p.priceInr / (p.durationDays / 30));

    return Scaffold(
      appBar: AppBar(
        title: const Text('DOP Collect Pro'),
        automaticallyImplyLeading: !widget.hardGate,
        actions: [
          IconButton(
            tooltip: 'Refresh status',
            icon: _restoring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
            onPressed: _restoring ? null : _restore,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _statusBanner(s),
          const SizedBox(height: 18),
          // No self-serve tier yet: pricing is set per agent from their book
          // size and how much they use it, so there is nothing here to sell.
          // Showing plan cards that can't be bought — or a checkout that would
          // charge the wrong number — is worse than showing none.
          if (!RemoteConfig.selfServeBilling) ...[
            _trialPanel(s),
            const SizedBox(height: 18),
            _legalFooter(),
          ] else ...[
            Text(_active ? 'Extend your plan' : 'Choose a plan',
                style: AppTheme.display(18, weight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Full access — sync, lists, portal submit and the assistant.',
                style: AppTheme.body(13, color: AppTheme.inkMuted)),
            if (!_checkoutReady) ...[
              const SizedBox(height: 8),
              Text('Paid plans open soon — checkout is being finalised.',
                  style: AppTheme.body(12,
                      weight: FontWeight.w700, color: AppTheme.amber)),
            ],
            const SizedBox(height: 14),
            if (plans.isEmpty)
              _plansLoadingOrRetry()
            else
              for (final p in plans)
                _planCard(p, isBest: p.code == best?.code, monthlyPerMo: monthly),
            const SizedBox(height: 20),
            _restoreRow(),
            const SizedBox(height: 18),
            _legalFooter(),
          ],
        ],
      ),
    );
  }

  /// What an agent sees while billing is still hand-set: their trial, what it
  /// covers, and what happens at the end — no prices, because there is no
  /// published price yet, and nothing to tap that would take money.
  Widget _trialPanel(SubStatus? s) {
    final ended = s?.expired ?? false;
    final days = s?.daysLeft ?? 0;
    final title = ended
        ? 'Your free trial has ended'
        : days > 0
            ? 'You have $days day${days == 1 ? '' : 's'} of free access'
            : 'Your free trial is running';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          decoration: AppTheme.card(fill: ended ? AppTheme.amberSoft : AppTheme.focal),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ended ? 'TRIAL ENDED' : 'FREE TRIAL',
                  style: AppTheme.label(AppTheme.ink)),
              const SizedBox(height: 8),
              Text(title,
                  style: AppTheme.display(21, weight: FontWeight.w800, height: 1.2)),
              const SizedBox(height: 8),
              Text(
                ended
                    ? 'Nothing has been charged. We\'ll agree a price with you '
                        'based on the size of your book and how much you use '
                        'the app, then set it up for you.'
                    : 'Everything is included, and nothing will be charged '
                        'automatically. Before it ends we\'ll agree a price '
                        'with you based on your book and how much you use it.',
                style: AppTheme.body(13.5, color: AppTheme.ink, height: 1.45),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('What you have', style: AppTheme.display(17, weight: FontWeight.w800)),
        const SizedBox(height: 10),
        _perk(Icons.sync_rounded, 'Sync your whole book',
            'Pull every account from the DOP portal, as often as you like.'),
        _perk(Icons.receipt_long_rounded, 'Lists and portal submit',
            'Build ₹20,000 lists and file them without typing them again.'),
        _perk(Icons.checklist_rounded, 'The collect round',
            'Daily and monthly collection, receipts, and the cash count.'),
        _perk(Icons.auto_awesome_rounded, 'The assistant',
            'Ask about your book in Hindi or English, by voice or typing.'),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: AppTheme.card(fill: AppTheme.surfaceSoft, radius: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.support_agent_rounded,
                  size: 20, color: AppTheme.inkMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  ended
                      ? 'Talk to us and we\'ll switch your access back on.'
                      : 'Questions about pricing? Talk to us any time.',
                  style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // The only action on this screen. An agent whose access was just
        // extended from the dashboard needs a way to pick it up without
        // reinstalling, and it is the honest thing to offer when the screen is
        // blocking them.
        Center(
          child: TextButton.icon(
            onPressed: _restoring ? null : _restore,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(_restoring ? 'Checking…' : 'Check again'),
          ),
        ),
      ],
    );
  }

  Widget _perk(IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: AppTheme.black),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTheme.body(14, weight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: AppTheme.body(12.5,
                          color: AppTheme.inkMuted, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );

  /// Shown only when there is genuinely nothing to list.
  ///
  /// It must always say WHY. Every blank-paywall incident so far looked
  /// identical from the outside — a missing build flag, a missing session, a
  /// dead network all produced the same empty rectangle, and each one cost a
  /// round trip to identify. The reason comes from [Subscription.lastStatusError]
  /// and is the difference between "I can fix this" and "the app is broken".
  Widget _plansLoadingOrRetry() {
    if (_s == null && _restoring) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
    }

    final why = Subscription.lastStatusError;
    final headline =
        why == null ? 'No plans are on sale right now.' : 'Couldn\'t load plans.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(headline,
              textAlign: TextAlign.center,
              style: AppTheme.body(13.5, weight: FontWeight.w700)),
          if (why != null) ...[
            const SizedBox(height: 6),
            Text(why,
                textAlign: TextAlign.center,
                style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
          ],
          const SizedBox(height: 4),
          Text(
            why == null
                ? 'Nothing to pay for — you can keep using the app.'
                : 'Your access is not affected while this is showing.',
            textAlign: TextAlign.center,
            style: AppTheme.body(11.5, color: AppTheme.inkFaint),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _restoring ? null : _restore,
            child: Text(_restoring ? 'Checking…' : 'Retry'),
          ),
        ]),
      ),
    );
  }

  Widget _statusBanner(SubStatus? s) {
    final (String text, Color tint, Color fg) = switch (s?.status) {
      'active' => (
          'Active · ${s!.daysLeft} day${s.daysLeft == 1 ? '' : 's'} left',
          AppTheme.greenSoft,
          AppTheme.green
        ),
      'trial' => (
          'Free trial · ${s!.daysLeft} day${s.daysLeft == 1 ? '' : 's'} left',
          AppTheme.focal,
          AppTheme.black
        ),
      'expired' => (
          'Your access has ended — subscribe to continue',
          AppTheme.redSoft,
          AppTheme.red
        ),
      _ => ('Subscribe for full access', AppTheme.surfaceSoft, AppTheme.inkMuted),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration:
          BoxDecoration(color: tint, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(Icons.workspace_premium_rounded, color: fg, size: 22),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: AppTheme.body(14, weight: FontWeight.w800, color: fg))),
      ]),
    );
  }

  Widget _planCard(Plan p, {required bool isBest, double? monthlyPerMo}) {
    final months = (p.durationDays / 30).round();
    final per = months > 0 ? p.priceInr / months : p.priceInr;
    // Savings vs the monthly plan's per-month price.
    int? savePct;
    if (monthlyPerMo != null && months > 1 && per < monthlyPerMo) {
      savePct = (100 * (1 - per / monthlyPerMo)).round();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        decoration: isBest
            ? AppTheme.card(radius: 18).copyWith(
                border: Border.all(color: AppTheme.black, width: 1.6),
              )
            : AppTheme.card(radius: 18),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(p.name,
                        style: AppTheme.display(17, weight: FontWeight.w800)),
                    if (isBest) ...[
                      const SizedBox(width: 8),
                      _pill('BEST VALUE', AppTheme.focal, AppTheme.black),
                    ],
                  ]),
                  const SizedBox(height: 3),
                  Text(
                    '${inr(p.priceInr)} · ${p.durationDays} days'
                    '${months > 1 ? ' · ~${inr(per)}/mo' : ''}',
                    style: AppTheme.body(12.5, color: AppTheme.inkMuted),
                  ),
                  if (savePct != null && savePct > 0) ...[
                    const SizedBox(height: 4),
                    Text('Save $savePct% vs monthly',
                        style: AppTheme.body(11.5,
                            weight: FontWeight.w700, color: AppTheme.green)),
                  ],
                ],
              ),
            ),
            SizedBox(
              width: 112,
              child: PushButton(
                onPressed: _busyPlan != null ? null : () => _choose(p),
                color: AppTheme.black,
                foreground: Colors.white,
                radius: 12,
                expand: false,
                child: _busyPlan == p.code
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_checkoutReady
                        ? (_active ? 'Extend' : 'Choose')
                        : 'Soon'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: AppTheme.body(9.5, weight: FontWeight.w800, color: fg)),
      );

  Widget _restoreRow() => Center(
        child: TextButton.icon(
          onPressed: _restoring ? null : _restore,
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: Text('I\'ve already paid — restore access',
              style: AppTheme.body(13, weight: FontWeight.w700)),
        ),
      );

  Widget _legalFooter() {
    Widget link(String label, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Text(label,
              style: AppTheme.body(11.5,
                      color: AppTheme.inkMuted, weight: FontWeight.w600)
                  .copyWith(decoration: TextDecoration.underline)),
        );
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          runSpacing: 6,
          children: [
            link('Privacy', () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrivacyScreen()))),
            link('Terms', () => _policyDialog('Terms of use', _termsText)),
            link('Refunds', () => _policyDialog('Cancellation & refunds', _refundText)),
          ],
        ),
        const SizedBox(height: 10),
        Text('Payments are processed securely by Razorpay. No auto-renewal — '
            'your plan simply ends and you re-subscribe.',
            textAlign: TextAlign.center,
            style: AppTheme.body(11, color: AppTheme.inkFaint, height: 1.35)),
      ],
    );
  }

  void _policyDialog(String title, String body) => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text(title, style: AppTheme.display(17)),
          content: SingleChildScrollView(
            child: Text(body,
                style: AppTheme.body(12.5, color: AppTheme.inkMuted, height: 1.5)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
          ],
        ),
      );

  static const _termsText =
      'DOP Collect Pro is a subscription to the app\'s collection tools (sync, '
      'lists, portal submission and the assistant). Access is tied to your DOP '
      'Agent ID for the plan\'s duration. The app assists with data entry only — '
      'it never moves money on your behalf; every payment on the post-office '
      'portal is made by you. Use the app in line with India Post rules.';

  static const _refundText =
      'Plans are one-time purchases for a fixed period (no auto-renewal) — when '
      'a plan ends, access simply stops until you subscribe again.\n\n'
      'If you were charged but access didn\'t activate, tap "I\'ve already paid — '
      'restore access"; activation can take a moment. For a duplicate or '
      'wrongful charge, contact support from Settings within 7 days and we\'ll '
      'verify and refund the transaction to your original payment method.';
}
