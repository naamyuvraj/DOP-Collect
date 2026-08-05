import 'package:flutter/material.dart';

import '../services/subscription.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/push_button.dart';

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

  /// Checkout can't run until the native Razorpay plugin is wired in a release
  /// build. Until then the paywall is preview-only.
  bool get _checkoutReady => Subscription.opener != null;

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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Payment successful — you\'re all set!')));
        Navigator.of(context).pop();
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

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  /// Show the real failure reason (so we can debug, not just "cancelled").
  void _showError(String msg) => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Payment didn\'t go through',
              style: AppTheme.display(17)),
          content: Text(msg,
              style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4)),
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
    final plans = (s?.plans ?? const <Plan>[]).where((p) => !p.isFree).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('DOP Collect Pro'),
        automaticallyImplyLeading: !widget.hardGate,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          _statusBanner(s),
          const SizedBox(height: 18),
          Text('Choose a plan',
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
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator()))
          else
            for (final p in plans) _planCard(p),
        ],
      ),
    );
  }

  Widget _statusBanner(SubStatus? s) {
    final (String text, Color tint, Color fg) = switch (s?.status) {
      'active' => ('Active · ${s!.daysLeft} days left', AppTheme.greenSoft, AppTheme.green),
      'trial' => ('Free trial · ${s!.daysLeft} days left', AppTheme.focal, AppTheme.black),
      'expired' => ('Your access has ended — subscribe to continue', AppTheme.redSoft, AppTheme.red),
      _ => ('Subscribe for full access', AppTheme.surfaceSoft, AppTheme.inkMuted),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
          color: tint, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(Icons.workspace_premium_rounded, color: fg, size: 22),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: AppTheme.body(14, weight: FontWeight.w800, color: fg))),
      ]),
    );
  }

  Widget _planCard(Plan p) {
    final months = (p.durationDays / 30).round();
    final per = months > 0 ? p.priceInr / months : p.priceInr;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        decoration: AppTheme.card(radius: 18),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      style: AppTheme.display(17, weight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text('${inr(p.priceInr)} · ${p.durationDays} days'
                      '${months > 1 ? ' · ~${inr(per)}/mo' : ''}',
                      style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
                ],
              ),
            ),
            SizedBox(
              width: 116,
              child: PushButton(
                onPressed: _busyPlan != null ? null : () => _choose(p),
                color: AppTheme.black,
                foreground: Colors.white,
                radius: 12,
                expand: false,
                child: Text(_busyPlan == p.code
                    ? '…'
                    : _checkoutReady
                        ? 'Choose'
                        : 'Soon'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
