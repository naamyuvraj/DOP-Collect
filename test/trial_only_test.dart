import 'dart:convert';

import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/screens/paywall_screen.dart';
import 'package:dop_collect/services/remote_config.dart';
import 'package:dop_collect/services/subscription.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_secure_storage.dart';

/// While pricing is agreed per agent, nothing in the app may sell anything.
///
/// There is no published tier: the price depends on the agent's book size and
/// how much they use it, and access is granted by hand from the dashboard. So
/// the plan cards and the checkout are hidden, and every purchase path is shut
/// — including from a stale screen or an older build that shipped before the
/// flag existed. The `pay` function refuses the same two actions server-side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  const plans = [
    {'code': 'monthly', 'name': 'Monthly', 'price_inr': 299, 'duration_days': 30},
    {'code': 'yearly', 'name': 'Yearly', 'price_inr': 2499, 'duration_days': 365},
  ];

  Future<void> arrive(
    WidgetTester tester, {
    required bool selfServe,
    required String status,
    int daysLeft = 21,
  }) async {
    Subscription.client = MockClient((_) async => http.Response(
        jsonEncode({
          'ok': true,
          'status': status,
          'planCode': status == 'trial' ? 'trial' : 'monthly',
          'periodEnd': DateTime.now()
              .toUtc()
              .add(Duration(days: status == 'expired' ? -2 : daysLeft))
              .toIso8601String(),
          'daysLeft': daysLeft,
          'plans': plans,
        }),
        200,
        headers: {'content-type': 'application/json'}));
    SharedPreferences.setMockInitialValues({
      'remote_config_v1': jsonEncode({
        'payments_enabled': true,
        'self_serve_billing': selfServe,
      }),
    });
    SupabaseConfig.testUrl = 'https://fake.supabase.test';
    SupabaseConfig.testAnonKey = 'anon-key-test';
    await tester.runAsync(() async {
      await SessionStore.save(
          const Session('tok', 'acct-1', '9810000001', 'AGENT-1'));
      await RemoteConfig.init();
      await Subscription.init();
      await Subscription.refresh();
    });
    Subscription.client = MockClient((_) async => throw const _Offline());
  }

  setUp(() => FakeSecureStorage.install());

  tearDown(() async {
    SupabaseConfig.testUrl = null;
    SupabaseConfig.testAnonKey = null;
    Subscription.client = http.Client();
    await SessionStore.clear();
    await Subscription.forget();
    FakeSecureStorage.remove();
  });

  group('with self-serve billing OFF', () {
    testWidgets('no plan is offered and nothing can be bought', (tester) async {
      await arrive(tester, selfServe: false, status: 'trial');
      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();

      expect(find.text('Monthly'), findsNothing);
      expect(find.text('Yearly'), findsNothing);
      expect(find.text('Choose a plan'), findsNothing);
      // No PRICE, specifically. "Build ₹20,000 lists" is the postal cap and is
      // fine — what must not appear is a number an agent could read as theirs.
      expect(find.textContaining('299'), findsNothing);
      expect(find.textContaining('2,499'), findsNothing);
      expect(find.textContaining('/mo'), findsNothing);
    });

    testWidgets('it shows the trial, and how long is left', (tester) async {
      await arrive(tester, selfServe: false, status: 'trial', daysLeft: 21);
      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();

      expect(find.text('FREE TRIAL'), findsOneWidget);
      expect(find.textContaining('21 days of free access'), findsOneWidget);
      expect(find.textContaining('nothing will be charged'), findsOneWidget);
    });

    testWidgets('an ended trial says so without asking for money',
        (tester) async {
      await arrive(tester, selfServe: false, status: 'expired', daysLeft: 0);
      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();

      expect(find.text('TRIAL ENDED'), findsOneWidget);
      expect(find.textContaining('Nothing has been charged'), findsOneWidget);
      expect(find.text('Choose a plan'), findsNothing);
    });

    testWidgets('it lists what the agent actually gets', (tester) async {
      await arrive(tester, selfServe: false, status: 'trial');
      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();

      expect(find.text('Sync your whole book'), findsOneWidget);
      expect(find.text('Lists and portal submit'), findsOneWidget);
      expect(find.text('The collect round'), findsOneWidget);
      expect(find.text('The assistant'), findsOneWidget);
    });

    testWidgets('there is a way to pick up access granted from the dashboard',
        (tester) async {
      await arrive(tester, selfServe: false, status: 'expired', daysLeft: 0);
      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();
      expect(find.text('Check again'), findsOneWidget);
    });

    test('purchase() refuses before it reaches the network', () async {
      SharedPreferences.setMockInitialValues({
        'remote_config_v1': '{"self_serve_billing": false}',
      });
      await RemoteConfig.init();
      var called = false;
      Subscription.client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });

      expect(await Subscription.purchase('monthly'), isFalse);
      expect(called, isFalse, reason: 'no order may even be attempted');
      expect(Subscription.lastError, contains('aren\'t on sale yet'));
    });
  });

  group('with self-serve billing ON, the shop comes back', () {
    testWidgets('plans are listed again', (tester) async {
      await arrive(tester, selfServe: true, status: 'trial');
      await tester.pumpWidget(const MaterialApp(home: PaywallScreen()));
      await tester.pump();

      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Yearly'), findsOneWidget);
      expect(find.text('FREE TRIAL'), findsNothing);
    });
  });
}

class _Offline implements Exception {
  const _Offline();
}
