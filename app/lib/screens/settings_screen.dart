import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/account_repository.dart';
import '../data/app_settings.dart';
import '../data/collection_repository.dart';
import '../data/credentials.dart';
import '../data/database.dart';
import '../main.dart';
import '../services/analytics.dart';
import '../services/otp_service.dart';
import '../services/subscription.dart';
import '../services/supabase_config.dart';
import '../services/cloud_sync.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_overlay.dart';
import '../widgets/push_button.dart';
import 'calculator_screen.dart';
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
    this.collections,
    this.onSynced,
    this.onTour,
  });
  final AccountRepository repo;

  /// Ledger, so a closed account opened from Matured Accounts still shows the
  /// khata of what that customer actually paid in.
  final CollectionRepository? collections;

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
  int _versionTaps = 0; // 7 taps reveals the debug tools

  @override
  void initState() {
    super.initState();
  }

  /// One line describing the book-wide daily rule as it stands.

  bool _cloudSyncing = false;

  /// The desktop's entire data path: pull whatever the phone has uploaded.
  Future<void> _cloudSync() async {
    if (_cloudSyncing) return;
    setState(() => _cloudSyncing = true);
    final r = await CloudSync.run();
    if (!mounted) return;
    setState(() => _cloudSyncing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(!r.ok
          ? r.message
          : r.changedAnything
              ? 'Synced — ${r.pulled} in, ${r.pushed} out.'
              : 'Already up to date.'),
      duration: const Duration(seconds: 3),
    ));
    if (r.pulled > 0) widget.onSynced?.call();
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
          'Your book is kept for this Agent ID — sign in again and it comes '
          'back exactly as it is.',
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
      // Close this agent's book.
      //
      // The file is NOT deleted — signing back in reopens it exactly as it was.
      // But it must stop being the OPEN book, or the next agent to sign in on
      // this phone collects against these customers. The sync cursors are keyed
      // on the agent too, so they stay with his book rather than being
      // inherited by whoever signs in next.
      await AppDatabase.instance.releaseAgent();
      await AppSettings.setOnboarded(false);
    }, message: 'Logging out…');
    DopCollectApp.onLogout?.call();
  }

  @override
  Widget build(BuildContext context) {
    // Settings is the one screen that must NOT use the width. It is a column
    // of independent switches read top to bottom, and a full-bleed 1,080 px
    // button is a worse target than a 560 px one, not a better one — the
    // pointer has further to travel and the label floats away from its
    // control. Every desktop OS caps this pane for the same reason.
    final wide = MediaQuery.of(context).size.width >= kDesktopBreakpoint;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: !wide,
        titleSpacing: 20,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 620 : double.infinity),
          child: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, wide ? 40 : 130),
        children: [
          _heading('DATA'),
          // All three of these drive the DOP portal in a WebView, which a
          // browser tab cannot do. Offering them here and landing the agent on
          // an explanation is worse than not offering them: the desktop's only
          // data action is pulling down what the phone uploaded.
          if (kIsWeb)
            _btn(_cloudSyncing ? 'Syncing…' : 'Sync from your phone',
                () {
              if (!_cloudSyncing) _cloudSync();
            }, primary: true)
          else ...[
            _btn('Sync Collection', _sync, primary: true),
            _btn('Deep Sync · last deposit', _deepSync, primary: true),
            _btn('Get ASLAAS numbers', _getAslaas, primary: true),
          ],
          // Matured Accounts lived here and is now on the home screen, under
          // Portfolio → Maturity, where finished accounts sit beside the ones
          // about to finish. One place for maturity, and it is the place he
          // already looks.

          const SizedBox(height: 8),
          _heading('TOOLS'),
          _btn(
              'Interest Calculator',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CalculatorScreen()))),
          _btn(
              'RD Interest Rates',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RdRatesScreen()))),

          const SizedBox(height: 8),
          _heading('APP'),
          // "Offline-only AI" and "Usage analytics" used to sit here. Both are
          // gone: the assistant now falls back to on-device answers by itself
          // when the network is out, and what analytics sends is disclosed in
          // the Privacy Policy the agent accepts at sign-up. Anything the agent
          // needs to KNOW is on that screen, one tap below.
          _btn(
              'Subscription',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PaywallScreen()))),
          if (widget.onTour != null)
            _btn('Take a tour', () => widget.onTour!()),
          _btn(
              'Khata backup',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const KhataBackupScreen()))),
          _btn(
              'Privacy & Safety',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PrivacyScreen()))),
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
          Center(
            child: GestureDetector(
              onTap: () => setState(() => _versionTaps++),
              child: Text('Version ${SettingsScreen._version}',
                  style: AppTheme.body(12, color: AppTheme.inkMuted)),
            ),
          ),
        ],
      ),
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
                ? AppTheme.onAccent
                : AppTheme.ink,
        radius: 14,
        child: Text(label),
      ),
    );
  }
}
