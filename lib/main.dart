import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'assistant/assistant_config.dart';
import 'data/account_repository.dart';
import 'data/app_settings.dart';
import 'data/rd_rates_store.dart';
import 'data/database.dart';
import 'data/lot_repository.dart';
import 'data/sample_data.dart';
import 'models/summaries.dart';
import 'screens/onboarding_login.dart';
import 'services/analytics.dart';
import 'shell.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const bool web = kIsWeb;
  final AccountRepository repo = web
      ? MemoryAccountRepository()
      : SqfliteAccountRepository(AppDatabase.instance);
  final LotRepository lots =
      web ? MemoryLotRepository() : SqfliteLotRepository(AppDatabase.instance);

  // Seed demo customers ONLY in the web UI preview. On the real device a fresh
  // install starts empty and honest — a 58-year-old must never open the app to
  // real-looking names he doesn't recognise (reads as "someone else's data").
  if (web && await repo.count() == 0) {
    await repo.replaceAll(sampleAccounts);
  }
  // Apply any user edits to the RD rate history before the UI reads rates.
  await RdRatesStore.load();
  // "New Accounts" window (default 1 month).
  AccountFilter.newAccountMonths = await AppSettings.newAccountMonths();
  // Honour the privacy toggle (offline-only AI) from the first question.
  AssistantConfig.userOfflineOnly = await AppSettings.offlineOnlyAi();

  // Anonymous analytics: load opt-out, register the install, log the open.
  await Analytics.init();
  unawaited(Analytics.identify());
  unawaited(Analytics.track('app_open'));

  // Web build is only for UI preview — skip the first-run gate there.
  final onboarded = web ? true : await AppSettings.onboarded();

  runApp(DopCollectApp(repo: repo, lots: lots, onboarded: onboarded));
}

class DopCollectApp extends StatefulWidget {
  const DopCollectApp({
    super.key,
    required this.repo,
    required this.lots,
    required this.onboarded,
  });
  final AccountRepository repo;
  final LotRepository lots;
  final bool onboarded;

  /// Set by the app root so Settings can log out (drops to onboarding).
  static void Function()? onLogout;

  @override
  State<DopCollectApp> createState() => _DopCollectAppState();
}

class _DopCollectAppState extends State<DopCollectApp> {
  late bool _onboarded = widget.onboarded;

  @override
  void initState() {
    super.initState();
    DopCollectApp.onLogout = () {
      if (mounted) setState(() => _onboarded = false);
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DOP Collect',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      // Respect Android's font-size setting but clamp it: below 1.0 the app
      // never shrinks, and past 1.3 the dense cards start to overflow. This
      // lets a large-font user scale up safely without breaking the layout.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 1.0,
        maxScaleFactor: 1.3,
        child: child ?? const SizedBox.shrink(),
      ),
      home: _onboarded
          ? MainShell(
              key: const ValueKey('shell'),
              repo: widget.repo,
              lots: widget.lots)
          : OnboardingLogin(
              key: const ValueKey('onboarding'),
              onDone: () => setState(() => _onboarded = true)),
    );
  }
}
