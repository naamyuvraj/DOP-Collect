import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/account_repository.dart';
import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../main.dart';
import '../models/daily_rule.dart';
import '../services/analytics.dart';
import '../services/otp_service.dart';
import '../services/subscription.dart';
import '../services/supabase_config.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/loading_overlay.dart';
import '../widgets/push_button.dart';
import 'calculator_screen.dart';
import 'change_mobile_screen.dart';
import 'debug_breakdown.dart';
import 'onboarding_login.dart';
import 'paywall_screen.dart';
import 'khata_backup_screen.dart';
import 'privacy_screen.dart';
import 'rd_rates_screen.dart';
import 'portal/sync_screen.dart';

/// Settings / actions: the ASLAAS number (used on every list), Sync Collection
/// (the real portal sync), Update Masterlist, etc.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repo,
    this.onSynced,
    this.onTour,
  });
  final AccountRepository repo;
  final VoidCallback? onSynced;

  /// Replays the guided product tour (owned by the shell, which holds the
  /// spotlight targets).
  final Future<void> Function()? onTour;

  /// Shown at the bottom of Settings. Derived, never hand-typed — this was a
  /// separate constant and had drifted three releases behind what the app
  /// actually was, so a support call started from the wrong version.
  static String get _version => SupabaseConfig.buildVersion;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DailyRule _dailyRule = DailyRule.standard;
  int _versionTaps = 0; // 7 taps reveals the debug tools

  @override
  void initState() {
    super.initState();
    AppSettings.dailyRule().then((v) {
      if (mounted) setState(() => _dailyRule = v);
    });
  }

  /// One line describing the book-wide daily rule as it stands.
  String get _dailyRuleLabel => _dailyRule.mode == DailyMode.flat
      ? 'Every customer pays ${inr(_dailyRule.flatAmount)} a visit'
      : 'A month\'s installment over ${_dailyRule.days} visits — '
          'e.g. ₹15,000 → ${inr(15000 ~/ _dailyRule.days)}, '
          '₹3,000 → ${inr((3000 / _dailyRule.days).ceil())}';

  Widget _ruleOption({
    required bool selected,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected ? AppTheme.black : AppTheme.inkFaint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppTheme.body(14, weight: FontWeight.w700)),
                    Text(subtitle,
                        style: AppTheme.body(12, color: AppTheme.inkFaint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  /// The agent's call, for the whole book: how many visits a month is spread
  /// over, or one flat amount for every account regardless of its value. A
  /// single customer can still be overridden from the collect sheet.
  Future<void> _editDailyRule() async {
    final daysCtrl = TextEditingController(text: '${_dailyRule.days}');
    final amtCtrl = TextEditingController(
        text: _dailyRule.flatAmount > 0 ? '${_dailyRule.flatAmount}' : '');
    var flat = _dailyRule.mode == DailyMode.flat;

    final saved = await showDialog<DailyRule>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Daily collection amount', style: AppTheme.display(17)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'How much a customer hands over on one visit, for every '
                  'account in your book.',
                  style:
                      AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
                ),
                const SizedBox(height: 14),
                _ruleOption(
                  selected: !flat,
                  title: 'Spread the month',
                  subtitle: 'Installment ÷ visits. ₹15,000 → ₹500.',
                  onTap: () => setLocal(() => flat = false),
                ),
                if (!flat)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 8),
                    child: TextField(
                      controller: daysCtrl,
                      keyboardType: TextInputType.number,
                      style: AppTheme.body(15, weight: FontWeight.w700),
                      decoration: const InputDecoration(
                          labelText: 'Visits in a month', hintText: '30'),
                    ),
                  ),
                _ruleOption(
                  selected: flat,
                  title: 'Same for everyone',
                  subtitle:
                      'One amount for every account, whatever it is worth.',
                  onTap: () => setLocal(() => flat = true),
                ),
                if (flat)
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: TextField(
                      controller: amtCtrl,
                      keyboardType: TextInputType.number,
                      style: AppTheme.body(15, weight: FontWeight.w700),
                      decoration: const InputDecoration(
                          prefixText: '₹ ', labelText: 'Every visit'),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                DailyRule(
                  mode: flat ? DailyMode.flat : DailyMode.perMonth,
                  days: int.tryParse(daysCtrl.text.trim()) ??
                      DailyRule.defaultDays,
                  flatAmount: int.tryParse(amtCtrl.text.trim()) ?? 0,
                ),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    // A flat rule with no amount would collect ₹1 a visit — keep the old one.
    if (saved.mode == DailyMode.flat && saved.flatAmount <= 0) return;
    await AppSettings.setDailyRule(saved);
    if (mounted) setState(() => _dailyRule = saved);
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _sync() async {
    if (!await ensureDopLogin(context) || !mounted) return;
    if (!await gatePremium(context) || !mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SyncScreen(repo: widget.repo)),
    );
    if (ok == true) widget.onSynced?.call();
  }

  /// Deep Sync: crawl per-account detail pages for exact last-deposit dates,
  /// totals and pending/default installments. Slower than Sync — run occasionally.
  Future<void> _deepSync() async {
    if (!await ensureDopLogin(context) || !mounted) return;
    if (!await gatePremium(context) || !mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => SyncScreen(repo: widget.repo, deepSync: true)),
    );
    if (ok == true) widget.onSynced?.call();
  }

  /// Read the portal's "ASLAAS Number Report" and fill each account's ASLAAS
  /// automatically — so it's never typed by hand. Run occasionally.
  Future<void> _getAslaas() async {
    if (!await ensureDopLogin(context) || !mounted) return;
    if (!await gatePremium(context) || !mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => SyncScreen(repo: widget.repo, aslaasSync: true)),
    );
    if (ok == true) widget.onSynced?.call();
  }

  /// Real logout: wipe the saved DOP login from the Keystore and drop back to
  /// the onboarding/login screen. Synced accounts stay on the device.
  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Log out?', style: AppTheme.display(18)),
        content: Text(
          'Your saved Agent ID and password will be removed from this phone. '
          'Your accounts stay on the device — sign in again to sync.',
          style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runWithLoader(context, () async {
      Analytics.track('logout');
      await Credentials.clear();
      // Entitlement belongs to the agent, not the phone.
      await Subscription.forget();
      // Revoke this device's OTP session server-side too (frees a device slot)
      // and wipe the local token. Best-effort — never let it block logout.
      try {
        await OtpService.logout();
      } catch (_) {/* ignore */}
      // Drop the portal's JSESSIONID too — otherwise the next person to open
      // Sync on this phone could land inside an already-authenticated banking
      // session. Best-effort: never let a cookie error block logout.
      try {
        await WebViewCookieManager().clearCookies();
      } catch (_) {/* ignore — credentials are already wiped */}
      await AppSettings.setOnboarded(false);
    }, message: 'Logging out…');
    DopCollectApp.onLogout?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 130),
        children: [
          _heading('DATA'),
          _btn('Sync Collection', _sync, primary: true),
          _btn('Deep Sync · last deposit', _deepSync, primary: true),
          _btn('Get ASLAAS numbers', _getAslaas, primary: true),

          const SizedBox(height: 8),
          _heading('COLLECTION'),
          _btn('Daily collection amount', _editDailyRule),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
            child: Text(_dailyRuleLabel,
                style: AppTheme.body(12, color: AppTheme.inkFaint)),
          ),

          const SizedBox(height: 8),
          _heading('TOOLS'),
          _btn(
              'Interest Calculator',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const CalculatorScreen()))),
          _btn(
              'RD Interest Rates',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const RdRatesScreen()))),

          const SizedBox(height: 8),
          _heading('APP'),
          // "Offline-only AI" and "Usage analytics" used to sit here. Both are
          // gone: the assistant now falls back to on-device answers by itself
          // when the network is out, and what analytics sends is disclosed in
          // the Privacy Policy the agent accepts at sign-up. Anything the agent
          // needs to KNOW is on that screen, one tap below.
          _btn(
              'Subscription',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PaywallScreen()))),
          if (widget.onTour != null)
            _btn('Take a tour', () => widget.onTour!()),
          _btn(
              'Khata backup',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const KhataBackupScreen()))),
          _btn(
              'Privacy & Safety',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PrivacyScreen()))),
          if (_versionTaps >= 7)
            _btn(
                'Data breakdown (debug)',
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DebugBreakdown(repo: widget.repo)))),

          const SizedBox(height: 8),
          _heading('ACCOUNT'),
          _btn(
              'Update mobile number',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ChangeMobileScreen()))),

          const SizedBox(height: 20),
          // Logout: at the very bottom, in red, well away from Sync so a
          // mis-tap can never wipe his saved login.
          _btn('Logout', _logout, danger: true),

          const SizedBox(height: 24),
          Center(
            child: GestureDetector(
              onTap: () => setState(() => _versionTaps++),
              child: Text('Version ${SettingsScreen._version}',
                  style: AppTheme.body(12, color: AppTheme.inkMuted)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Text(text, style: AppTheme.label(AppTheme.inkMuted)),
      );

  Widget _btn(String label, VoidCallback onTap,
      {bool primary = false, bool danger = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: PushButton(
        onPressed: onTap,
        color: danger
            ? AppTheme.redSoft
            : primary
                ? AppTheme.black
                : AppTheme.surface,
        foreground: danger
            ? AppTheme.red
            : primary
                ? Colors.white
                : AppTheme.ink,
        radius: 14,
        child: Text(label),
      ),
    );
  }
}
