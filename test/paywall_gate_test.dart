import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/collection_repository.dart';
import 'package:dop_collect/data/lot_repository.dart';
import 'package:dop_collect/main.dart';
import 'package:dop_collect/screens/paywall_screen.dart';
import 'package:dop_collect/services/remote_config.dart';
import 'package:dop_collect/services/subscription.dart';
import 'package:dop_collect/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The paywall used to be wired to exactly one button (Settings -> Sync), so an
/// expired agent could just sync from Home instead. The gate now sits at the
/// app root, where no screen can route around it. These tests pump the REAL
/// root widget — if the gate is ever unwired, they go red.
///
/// Both switches are driven the way the app really loads them: RemoteConfig and
/// Subscription each read a cached JSON blob out of SharedPreferences at
/// startup, so seeding prefs is enough to reach any entitlement state without
/// touching the network.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Never let the theme reach out for a webfont mid-test.
  GoogleFonts.config.allowRuntimeFetching = false;

  Future<void> boot({
    required bool paymentsEnabled,
    required String status,
  }) async {
    SharedPreferences.setMockInitialValues({
      'remote_config_v1': '{"payments_enabled": $paymentsEnabled}',
      'sub_status_v1':
          '{"status":"$status","planCode":"m1","daysLeft":${status == 'expired' ? 0 : 12}}',
    });
    await RemoteConfig.init();
    await Subscription.init();
  }

  Widget app() => DopCollectApp(
        repo: MemoryAccountRepository(),
        lots: MemoryLotRepository(),
        collections: MemoryCollectionRepository(),
        onboarded: true,
      );

  testWidgets('an expired plan is stopped at the app root', (tester) async {
    await boot(paymentsEnabled: true, status: 'expired');
    expect(Subscription.blocked, isTrue, reason: 'precondition');

    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.byType(PaywallScreen), findsOneWidget);
    expect(find.byType(MainShell), findsNothing,
        reason: 'an expired agent must not reach the app at all');
  });

  testWidgets('the gate is a HARD gate — no back button out of it',
      (tester) async {
    await boot(paymentsEnabled: true, status: 'expired');
    await tester.pumpWidget(app());
    await tester.pump();

    final paywall = tester.widget<PaywallScreen>(find.byType(PaywallScreen));
    expect(paywall.hardGate, isTrue);
  });

  testWidgets('an active plan reaches the app', (tester) async {
    await boot(paymentsEnabled: true, status: 'active');
    expect(Subscription.blocked, isFalse);

    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.byType(PaywallScreen), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);
  });

  testWidgets('a trial reaches the app', (tester) async {
    await boot(paymentsEnabled: true, status: 'trial');
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byType(MainShell), findsOneWidget);
  });

  testWidgets('with payments OFF, even an expired plan is let through',
      (tester) async {
    // The kill switch has to work in this direction too: until the paywall is
    // switched on, nobody may be blocked by a stale cached status.
    await boot(paymentsEnabled: false, status: 'expired');
    expect(Subscription.blocked, isFalse);

    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.byType(PaywallScreen), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);
  });

  testWidgets('an unknown status fails OPEN — never lock out a paying agent',
      (tester) async {
    // Fresh install, offline, or the status call failed: no cached entitlement.
    SharedPreferences.setMockInitialValues({
      'remote_config_v1': '{"payments_enabled": true}',
    });
    await RemoteConfig.init();
    await Subscription.init();
    expect(Subscription.blocked, isFalse);

    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byType(MainShell), findsOneWidget);
  });

  test('entitlement does not survive a logout onto the next agent', () async {
    // Agent A is paid up on this phone.
    SharedPreferences.setMockInitialValues({
      'remote_config_v1': '{"payments_enabled": true}',
      'sub_status_v1': '{"status":"active","planCode":"y1","daysLeft":300}',
    });
    await RemoteConfig.init();
    await Subscription.init();
    expect(Subscription.current?.planCode, 'y1');

    await Subscription.forget();
    expect(Subscription.current, isNull, reason: 'cleared in memory');

    // Agent B signs in on the same phone: starts from "unknown", not A's plan.
    await Subscription.init();
    expect(Subscription.current, isNull, reason: 'cleared on disk too');
    expect(Subscription.blocked, isFalse, reason: 'unknown must fail open');
  });

  testWidgets('the gate clears the moment a purchase lands', (tester) async {
    await boot(paymentsEnabled: true, status: 'expired');
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byType(PaywallScreen), findsOneWidget);

    // What Subscription.refresh() does after a verified payment: update the
    // cached status, then fire onChanged. Without that callback the root would
    // sit on the paywall until the next cold start.
    SharedPreferences.setMockInitialValues({
      'remote_config_v1': '{"payments_enabled": true}',
      'sub_status_v1': '{"status":"active","planCode":"m1","daysLeft":30}',
    });
    await Subscription.init();
    Subscription.onChanged?.call();
    await tester.pump();

    expect(find.byType(PaywallScreen), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);
  });
}
