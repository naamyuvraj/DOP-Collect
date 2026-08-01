import 'package:flutter/material.dart';

import '../assistant/assistant_config.dart';
import '../data/account_repository.dart';
import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../main.dart';
import '../services/analytics.dart';
import '../theme/app_theme.dart';
import '../widgets/developer_card.dart';
import '../widgets/push_button.dart';
import 'calculator_screen.dart';
import 'debug_breakdown.dart';
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

  static const _version = '0.9.37';

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _aslaasCtrl = TextEditingController();
  final _aslaasFocus = FocusNode();
  bool _offlineAi = false;
  bool _analytics = true;
  int _versionTaps = 0; // 7 taps reveals the debug tools

  @override
  void initState() {
    super.initState();
    AppSettings.aslaas().then((v) => _aslaasCtrl.text = v);
    AppSettings.offlineOnlyAi().then((v) {
      if (mounted) setState(() => _offlineAi = v);
    });
    AppSettings.analyticsEnabled().then((v) {
      if (mounted) setState(() => _analytics = v);
    });
    // Auto-save ASLAAS when the field loses focus — no silent discard.
    _aslaasFocus.addListener(() {
      if (!_aslaasFocus.hasFocus) AppSettings.setAslaas(_aslaasCtrl.text);
    });
  }

  Future<void> _setOfflineAi(bool v) async {
    setState(() => _offlineAi = v);
    Analytics.track('setting_toggle', {'name': 'offline_ai', 'on': v});
    await AppSettings.setOfflineOnlyAi(v);
    AssistantConfig.userOfflineOnly = v;
  }

  Future<void> _setAnalytics(bool v) async {
    setState(() => _analytics = v);
    // Record the choice BEFORE applying, so an opt-out itself is still sent.
    Analytics.track('setting_toggle', {'name': 'analytics', 'on': v});
    await AppSettings.setAnalyticsEnabled(v);
    Analytics.setEnabled(v);
  }

  @override
  void dispose() {
    _aslaasCtrl.dispose();
    _aslaasFocus.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SyncScreen(repo: widget.repo)),
    );
    if (ok == true) widget.onSynced?.call();
  }

  /// Deep Sync: crawl per-account detail pages for exact last-deposit dates,
  /// totals and pending/default installments. Slower than Sync — run occasionally.
  Future<void> _deepSync() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => SyncScreen(repo: widget.repo, deepSync: true)),
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
    if (ok != true) return;
    Analytics.track('logout');
    await Credentials.clear();
    await AppSettings.setOnboarded(false);
    DopCollectApp.onLogout?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 130),
        children: [
          _aslaasField(),
          const SizedBox(height: 20),

          _heading('DATA'),
          _btn('Sync Collection', _sync, primary: true),
          _btn('Deep Sync · last deposit', _deepSync, primary: true),

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
          _toggleTile(
              'Offline-only AI',
              'Assistant answers on-device only. Nothing — not even the '
                  'question — leaves the phone.',
              _offlineAi,
              _setOfflineAi),
          _toggleTile(
              'Usage analytics',
              'Anonymous app usage (no customer data) to improve the app.',
              _analytics,
              _setAnalytics),
          if (widget.onTour != null)
            _btn('Take a tour', () => widget.onTour!()),
          _btn(
              'Privacy & Safety',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PrivacyScreen()))),
          if (_versionTaps >= 7)
            _btn(
                'Data breakdown (debug)',
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DebugBreakdown(repo: widget.repo)))),

          const SizedBox(height: 20),
          // Logout: at the very bottom, in red, well away from Sync so a
          // mis-tap can never wipe his saved login.
          _btn('Logout', _logout, danger: true),

          const SizedBox(height: 24),
          const DeveloperCard(),
          const SizedBox(height: 20),
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

  Widget _aslaasField() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ASLAAS NUMBER', style: AppTheme.label(AppTheme.inkMuted)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _aslaasCtrl,
                  focusNode: _aslaasFocus,
                  keyboardType: TextInputType.number,
                  style: AppTheme.body(16, weight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: 'e.g. 1234567',
                    hintStyle: AppTheme.body(15, color: AppTheme.inkFaint),
                    isDense: true,
                    enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: AppTheme.line)),
                    focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: AppTheme.accent)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                onPressed: () async {
                  await AppSettings.setAslaas(_aslaasCtrl.text);
                  if (!mounted) return;
                  FocusScope.of(context).unfocus();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('ASLAAS saved')));
                },
                child: const Text('Save'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Shown on every list to key into the portal.',
              style: AppTheme.body(11, color: AppTheme.inkMuted)),
        ],
      ),
    );
  }

  Widget _toggleTile(
      String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        decoration: AppTheme.card(radius: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTheme.body(15, weight: FontWeight.w600)),
                  Text(subtitle,
                      style: AppTheme.body(11, color: AppTheme.inkMuted)),
                ],
              ),
            ),
            Switch(
              value: value,
              activeThumbColor: AppTheme.accent,
              onChanged: onChanged,
            ),
          ],
        ),
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
