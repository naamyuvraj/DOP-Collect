import 'dart:convert';

import 'package:dop_collect/data/account_repository.dart';
import 'package:dop_collect/data/collection_repository.dart';
import 'package:dop_collect/data/lot_repository.dart';
import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/main.dart';
import 'package:dop_collect/screens/paywall_screen.dart';
import 'package:dop_collect/services/remote_config.dart';
import 'package:dop_collect/services/subscription.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:dop_collect/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  group('the paywall renders its plans', () {
    // The regression this group exists for: locking `pay` behind a session made
    // the client skip the request entirely, so the screen loaded a cached
    // status with an empty plan list and showed "Couldn't load plans." above a
    // Retry button that re-ran the same skipped call. Blank, forever.
    const plansReply = {
      'ok': true,
      'status': 'unknown',
      'planCode': '',
      'daysLeft': 0,
      'plans': [
        {'code': 'm1', 'name': 'Monthly', 'price_inr': 199, 'duration_days': 30},
        {'code': 'y1', 'name': 'Yearly', 'price_inr': 1499, 'duration_days': 365},
      ],
    };

    /// Arrange the state the paywall opens in, with the network already faked.
    ///
    /// Runs inside [WidgetTester.runAsync] on purpose. `MockClient` delivers
    /// its body through a Stream, and a Stream cannot advance inside
    /// `testWidgets`' fake-async zone unless something pumps — so awaiting the
    /// refresh in the normal test body deadlocks instead of failing. runAsync
    /// gives it the real event loop.
    ///
    /// The mock is installed FIRST because `Subscription.init()` kicks off an
    /// unawaited refresh; install it later and that call escapes to the real
    /// network.
    Future<void> arrive(
      WidgetTester tester, {
      required List<Map<String, Object>> plans,
    }) async {
      Subscription.client = MockClient((_) async => http.Response(
          jsonEncode({...plansReply, 'plans': plans}), 200,
          headers: {'content-type': 'application/json'}));
      SharedPreferences.setMockInitialValues({
        // A cached status with no plans: exactly the state that went blank.
        'sub_status_v1': '{"status":"trial","planCode":"trial","daysLeft":3}',
      });
      SupabaseConfig.testUrl = 'https://fake.supabase.test';
      SupabaseConfig.testAnonKey = 'anon-key-test';
      await tester.runAsync(() async {
        await SessionStore.clear();
        await Subscription.init();
        // Settle the entitlement the screen reads on its first frame.
        await Subscription.refresh();
      });
      // The screen refreshes again from initState, back inside the fake zone.
      // Make that fail immediately so it leaves no Stream or timeout Timer
      // pending; refresh() then returns the entitlement we just settled.
      Subscription.client = MockClient((_) async => throw const _Offline());
    }

    tearDown(() async {
      Subscription.client = http.Client();
      SupabaseConfig.testUrl = null;
      SupabaseConfig.testAnonKey = null;
      await Subscription.forget();
    });

    testWidgets('with NO session — prices are public', (tester) async {
      await arrive(tester, plans: const [
        {'code': 'm1', 'name': 'Monthly', 'price_inr': 199, 'duration_days': 30},
        {'code': 'y1', 'name': 'Yearly', 'price_inr': 1499, 'duration_days': 365},
      ]);

      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();

      expect(find.text("Couldn't load plans."), findsNothing);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Yearly'), findsOneWidget);
    });

    testWidgets('a genuinely empty plan list says so, and still offers Retry',
        (tester) async {
      // Not every empty paywall is the bug. If the server answers fine and the
      // plans table really is empty, that is a different sentence from "we
      // couldn't reach the server" — and the agent needs to be told which,
      // because only one of them is something they can wait out.
      await arrive(tester, plans: const []);

      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();

      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Monthly'), findsNothing);
      // Never the bare blank rectangle: something explains the state.
      expect(
        find.textContaining('plan', findRichText: true),
        findsWidgets,
        reason: 'the screen must say what is going on, whichever case it is',
      );
    });
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

class _Offline implements Exception {
  const _Offline();
}
