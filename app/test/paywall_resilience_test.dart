import 'dart:convert';

import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/services/subscription.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_secure_storage.dart';

/// The paywall must never go blank again.
///
/// It went blank three times in a row for three different reasons — a build
/// with no dart-defines, a session requirement that was too broad, and a plain
/// failed request — and every one of them looked identical to the agent: an
/// empty rectangle over a Retry button that re-ran the same failing call.
///
/// The root cause underneath all three was the same: the plan list was fetched
/// fresh every time and cached nowhere, so the screen could only render while a
/// live call was succeeding. These tests hold the prices on disk and pin the
/// behaviour for every way a refresh can fail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const livePlans = [
    {'code': 'trial', 'name': 'Free trial', 'price_inr': 0, 'duration_days': 60},
    {'code': 'monthly', 'name': 'Monthly', 'price_inr': 299, 'duration_days': 30},
    {'code': 'yearly', 'name': 'Yearly', 'price_inr': 2499, 'duration_days': 365},
  ];

  Map<String, dynamic> okBody({List<Map<String, Object>> plans = livePlans}) => {
        'ok': true,
        'status': 'unknown',
        'planCode': '',
        'periodEnd': null,
        'daysLeft': 0,
        'plans': plans,
      };

  void serve(Map<String, dynamic> body, {int status = 200}) {
    Subscription.client = MockClient((_) async => http.Response(
        jsonEncode(body), status,
        headers: {'content-type': 'application/json'}));
  }

  void die() {
    Subscription.client = MockClient((_) async => throw const _Dead());
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FakeSecureStorage.install();
    SupabaseConfig.testUrl = 'https://fake.supabase.test';
    SupabaseConfig.testAnonKey = 'anon-key-test';
    await SessionStore.clear();
    await Subscription.forget();
    Subscription.lastStatusError = null;
  });

  tearDown(() async {
    SupabaseConfig.testUrl = null;
    SupabaseConfig.testAnonKey = null;
    Subscription.client = http.Client();
    await Subscription.forget();
    FakeSecureStorage.remove();
  });

  /// One successful visit, so the device has seen the prices once.
  Future<void> seenOnce() async {
    serve(okBody());
    await Subscription.refresh();
    expect(Subscription.current!.plans.length, 3, reason: 'precondition');
  }

  group('once the prices have been seen, they survive anything', () {
    test('a dead network', () async {
      await seenOnce();
      die();
      await Subscription.refresh();
      expect(Subscription.current!.plans.length, 3);
      expect(Subscription.lastStatusError, 'No connection.');
    });

    test('a cold start with no network at all', () async {
      await seenOnce();
      // Simulate relaunching: memory cleared, disk kept, still offline.
      final p = await SharedPreferences.getInstance();
      final keptStatus = p.getString('sub_status_v1');
      final keptPlans = p.getString('sub_plans_v1');
      expect(keptPlans, isNotNull, reason: 'prices must reach disk');

      SharedPreferences.setMockInitialValues({
        if (keptStatus != null) 'sub_status_v1': keptStatus,
        'sub_plans_v1': keptPlans!,
      });
      die();
      await Subscription.init();

      expect(Subscription.current, isNotNull);
      expect(Subscription.current!.plans.length, 3,
          reason: 'this is the case that went blank on every relaunch');
    });

    test('a rate limit', () async {
      await seenOnce();
      serve({'ok': false, 'error': 'rate_limited'}, status: 429);
      await Subscription.refresh();
      expect(Subscription.current!.plans.length, 3);
      expect(Subscription.lastStatusError, contains('Too many'));
    });

    test('a 500 from the server', () async {
      await seenOnce();
      serve({'ok': false, 'error': 'boom'}, status: 500);
      await Subscription.refresh();
      expect(Subscription.current!.plans.length, 3);
      expect(Subscription.lastStatusError, contains('boom'));
    });

    test('a captive portal serving HTML instead of JSON', () async {
      await seenOnce();
      Subscription.client = MockClient((_) async =>
          http.Response('<html>Sign in to WiFi</html>', 200,
              headers: {'content-type': 'text/html'}));
      await Subscription.refresh();
      expect(Subscription.current!.plans.length, 3);
      expect(Subscription.lastStatusError, 'No connection.');
    });

    test('an ok response that carries no plans', () async {
      // A hiccup, or someone deactivating every row mid-edit in the dashboard.
      await seenOnce();
      serve(okBody(plans: const []));
      await Subscription.refresh();
      expect(Subscription.current!.plans.length, 3,
          reason: 'an empty answer must not erase a known price list');
    });

    test('a session that went away', () async {
      await seenOnce();
      serve(okBody()); // server answers `unknown` for a signed-out device
      await Subscription.refresh();
      expect(Subscription.current!.plans.length, 3);
    });
  });

  group('the failure always says why', () {
    test('a build with no dart-defines names itself', () async {
      // The exact production incident: a Shorebird patch built without
      // --dart-define-from-file=env.json disables every cloud call at once.
      SupabaseConfig.testUrl = null;
      SupabaseConfig.testAnonKey = null;
      await Subscription.refresh();
      expect(Subscription.lastStatusError, contains('no server configuration'));
    });

    test('a signed-out device is told to sign in, not left guessing', () async {
      serve({'ok': false, 'error': 'unauthorized'}, status: 401);
      await Subscription.refresh();
      expect(Subscription.lastStatusError, contains('Sign in'));
    });

    test('a success clears the previous reason', () async {
      die();
      await Subscription.refresh();
      expect(Subscription.lastStatusError, isNotNull);
      serve(okBody());
      await Subscription.refresh();
      expect(Subscription.lastStatusError, isNull);
    });
  });

  group('none of this weakens the gate', () {
    test('a failed refresh never blocks an agent', () async {
      await seenOnce();
      die();
      await Subscription.refresh();
      expect(Subscription.blocked, isFalse);
    });

    test('cached prices do not grant entitlement', () async {
      await seenOnce();
      // Prices cached, but the device has no plan of its own.
      expect(Subscription.current!.status, 'unknown');
      expect(Subscription.current!.planCode, '');
      expect(Subscription.current!.daysLeft, 0);
    });
  });
}

class _Dead implements Exception {
  const _Dead();
}
