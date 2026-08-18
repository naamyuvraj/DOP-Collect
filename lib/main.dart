import 'dart:async';

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'assistant/assistant_config.dart';
import 'screens/force_update_screen.dart';
import 'screens/paywall_screen.dart';
import 'services/razorpay_checkout.dart';
import 'services/remote_config.dart';
import 'services/subscription.dart';
import 'data/account_repository.dart';
import 'data/app_settings.dart';
import 'data/rd_rates_store.dart';
import 'data/database.dart';
import 'data/collection_repository.dart';
import 'data/lot_repository.dart';
import 'data/sample_data.dart';
import 'models/summaries.dart';
import 'data/credentials.dart';
import 'screens/onboarding_login.dart';
import 'screens/verify_gate_screen.dart';
import 'data/session.dart';
import 'services/analytics.dart';
import 'services/otp_service.dart';
import 'services/update_service.dart';
import 'shell.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Anything Flutter catches during build/layout/paint. Without this the app
  // reported nothing but success — every event type it emitted was a
  // happy-path one, so the dashboard could never show a failure.
  final void Function(FlutterErrorDetails)? priorOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    priorOnError?.call(details);
    Analytics.error(
      'flutter',
      details.exceptionAsString(),
      detail: details.stack?.toString(),
      screen: details.library,
    );
  };

  // Errors thrown outside the framework's own zone — async gaps, isolates.
  PlatformDispatcher.instance.onError = (Object e, StackTrace st) {
    Analytics.error('uncaught', e.toString(), detail: st.toString());
    return false; // keep the default logging as well
  };

  const bool web = kIsWeb;
  final AccountRepository repo = web
      ? MemoryAccountRepository()
      : SqfliteAccountRepository(AppDatabase.instance);
  final LotRepository lots =
      web ? MemoryLotRepository() : SqfliteLotRepository(AppDatabase.instance);
  final CollectionRepository collections = web
      ? MemoryCollectionRepository()
      : SqfliteCollectionRepository(AppDatabase.instance);

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
  // Fold the retired second name ("display name") into the single Agent name.
  await AppSettings.migrateLegacyName();

  // Remote config (admin-dashboard controlled): loads instantly from cache,
  // refreshes in the background. Read the flags it exposes right after.
  await RemoteConfig.init();
  AssistantConfig.cloudEnabled = RemoteConfig.assistantCloud;
  // Subscription entitlement (cached instantly, refreshed in the background).
  // Inert until app_config.payments_enabled is turned on.
  Subscription.opener = RazorpayCheckout.open; // wire the native checkout sheet
  unawaited(Subscription.init());

  // Anonymous analytics: always on for the device (disclosed in the Privacy
  // Policy accepted at sign-up), but still killable fleet-wide from the
  // dashboard. Register the install, log the open.
  await Analytics.init(defaultEnabled: RemoteConfig.analyticsDefault);
  unawaited(Analytics.identify());
  unawaited(Analytics.track('app_open'));

  // Silently download any Shorebird patch in the background so it stages itself
  // with no user action — the Home banner then offers a one-tap restart, and it
  // applies on the next cold start regardless. (Fixes the old "open twice"
  // behaviour where the patch only downloaded when the user tapped Update.)
  if (!web) unawaited(UpdateService().downloadUpdate());

  // Web build is only for UI preview — skip the first-run gate there.
  final onboarded = web ? true : await AppSettings.onboarded();

  // OTP gate (option b — enforce the agent↔phone pair for EVERYONE, not only new
  // onboardings): an already-onboarded user with OTP on but no verified session
  // on this device must verify before using the app. Computed up front so the
  // gate shows instantly; the heartbeat below refines it (revoked session).
  final needsVerify = !web &&
      onboarded &&
      RemoteConfig.otpRequired &&
      !(await SessionStore.exists);

  runApp(DopCollectApp(
      repo: repo,
      lots: lots,
      collections: collections,
      onboarded: onboarded,
      needsVerify: needsVerify));

  // 2-device enforcement: if OTP is on and this device's session was revoked
  // remotely (kicked by the 2-device limit, or disabled by an admin), drop to
  // the verify gate on this launch. Background so it never delays startup, and
  // fail-open on a network blip.
  if (!web && onboarded) unawaited(_enforceSession());
}

/// Startup session heartbeat. Only acts when OTP is required AND the server says
/// this device's existing session is no longer valid; otherwise it's a no-op.
Future<void> _enforceSession() async {
  try {
    if (!RemoteConfig.otpRequired) return;
    if (!await SessionStore.exists) return; // no session → gate already shown
    if (await OtpService.sessionValid()) return; // valid, or offline (fail-open)
    // Session revoked (2-device limit / disabled): drop to the verify gate,
    // keeping the user onboarded so their setup isn't wiped.
    await SessionStore.clear();
    OtpService.signedOutRemotely = true; // the gate surfaces the reason
    if (DopCollectApp.setNeedsVerify != null) {
      DopCollectApp.setNeedsVerify!(true);
    } else {
      DopCollectApp.pendingNeedsVerify = true; // root not listening yet
    }
  } catch (_) {/* never let this crash startup */}
}

class DopCollectApp extends StatefulWidget {
  const DopCollectApp({
    super.key,
    required this.repo,
    required this.lots,
    required this.collections,
    required this.onboarded,
    this.needsVerify = false,
  });
  final AccountRepository repo;
  final LotRepository lots;
  final CollectionRepository collections;
  final bool onboarded;
  final bool needsVerify;

  /// Set by the app root so Settings can log out (drops to onboarding).
  static void Function()? onLogout;

  /// Set by the app root so the startup heartbeat can raise the verify gate.
  static void Function(bool)? setNeedsVerify;

  /// Set when the heartbeat finds a revoked session BEFORE the root widget has
  /// registered [setNeedsVerify].
  ///
  /// `_enforceSession()` is fired unawaited from main() and calls
  /// `setNeedsVerify?.call(true)`. That static is assigned in the root's
  /// initState, so if the heartbeat ever won the race the call was a silent
  /// no-op: the session had already been cleared, but the gate never rose and
  /// the agent kept using the app until the next launch. A network round-trip
  /// makes initState the overwhelming favourite — which is exactly why this
  /// would have been miserable to reproduce.
  static bool pendingNeedsVerify = false;

  @override
  State<DopCollectApp> createState() => _DopCollectAppState();
}

class _DopCollectAppState extends State<DopCollectApp> {
  late bool _onboarded = widget.onboarded;
  late bool _needsVerify = widget.needsVerify;

  @override
  void initState() {
    super.initState();
    DopCollectApp.onLogout = () {
      if (mounted) {
        setState(() {
          _onboarded = false;
          _needsVerify = false;
        });
      }
    };
    DopCollectApp.setNeedsVerify = (v) {
      if (mounted) setState(() => _needsVerify = v);
    };
    // Claim anything the heartbeat raised before we were listening.
    if (DopCollectApp.pendingNeedsVerify) {
      DopCollectApp.pendingNeedsVerify = false;
      _needsVerify = true;
    }
    // Entitlement can change under us (background refresh, or a purchase that
    // just completed), so rebuild rather than leave a stale gate on screen.
    Subscription.onChanged = () {
      if (mounted) setState(() {});
    };
  }

  /// Full sign-out from the verify gate: wipe credentials + session, drop to
  /// onboarding.
  Future<void> _fullLogout() async {
    await Credentials.clear();
    await OtpService.logout();
    await Subscription.forget();
    await AppSettings.setOnboarded(false);
    if (mounted) {
      setState(() {
        _onboarded = false;
        _needsVerify = false;
      });
    }
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
      home: RemoteConfig.updateRequired
          ? const ForceUpdateScreen()
          : !_onboarded
              ? OnboardingLogin(
                  key: const ValueKey('onboarding'),
                  onDone: () => setState(() => _onboarded = true))
              : _needsVerify
                  ? VerifyGateScreen(
                      key: const ValueKey('verify-gate'),
                      // Says what to DO, in one line. It used to name how
                      // many phones the plan allows, which told him a rule he
                      // cannot act on and does not need.
                      reason: OtpService.signedOutRemotely
                          ? 'Your account is open on another phone. Log out '
                              'there, then verify here.'
                          : null,
                      onVerified: () {
                        OtpService.signedOutRemotely = false;
                        setState(() => _needsVerify = false);
                      },
                      onLogout: _fullLogout,
                    )
                  // Access has ended. Gating the premium ACTIONS one by one
                  // leaves the rest of a paid app free, and every new screen is
                  // another place to forget — so the gate sits here, once,
                  // where nothing can route around it. Inert until payments are
                  // switched on, and fail-open: an unknown or unreachable
                  // status never blocks (see Subscription.blocked).
                  : Subscription.blocked
                      ? const PaywallScreen(
                          key: ValueKey('paywall-gate'), hardGate: true)
                      : MainShell(
                          key: const ValueKey('shell'),
                          repo: widget.repo,
                          lots: widget.lots,
                          collections: widget.collections),
    );
  }
}
