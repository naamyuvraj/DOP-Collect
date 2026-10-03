import 'dart:convert';

import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/services/subscription.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_secure_storage.dart';

/// "N days left" has to stay true after the moment the server said it.
///
/// The count was cached as a bare number and replayed on every later cold
/// start, so an agent who went a week without a successful refresh still read
/// the figure from a week ago. The expiry instant is now cached alongside it
/// and the count is derived from that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String iso(Duration fromNow) =>
      DateTime.now().toUtc().add(fromNow).toIso8601String();

  Map<String, dynamic> statusBody({
    required String status,
    required String periodEnd,
    int daysLeft = 999, // deliberately wrong: the client must not trust it
  }) =>
      {
        'ok': true,
        'status': status,
        'planCode': 'monthly',
        'periodEnd': periodEnd,
        'daysLeft': daysLeft,
        'plans': const [],
      };

  void stub(Map<String, dynamic> body) {
    Subscription.client = MockClient((_) async => http.Response(
        jsonEncode(body), 200, headers: {'content-type': 'application/json'}));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FakeSecureStorage.install();
    SupabaseConfig.testUrl = 'https://fake.supabase.test';
    SupabaseConfig.testAnonKey = 'anon-key-test';
    await SessionStore.save(
        const Session('tok', 'acct-1', '9810000001', 'AGENT-1'));
    await Subscription.forget();
  });

  tearDown(() async {
    SupabaseConfig.testUrl = null;
    SupabaseConfig.testAnonKey = null;
    Subscription.client = http.Client();
    await SessionStore.clear();
    await Subscription.forget();
    FakeSecureStorage.remove();
  });

  group('the count comes from the expiry, not from the server number', () {
    test('30 days out reads as 30', () async {
      stub(statusBody(status: 'active', periodEnd: iso(const Duration(days: 30))));
      await Subscription.refresh();
      expect(Subscription.current!.daysLeft, 30);
    });

    test('a part day counts as a whole day, never as zero', () async {
      // 30 minutes of access left is still access — "0 days left" beside an
      // account that still works reads as a bug.
      stub(statusBody(
          status: 'active', periodEnd: iso(const Duration(minutes: 30))));
      await Subscription.refresh();
      expect(Subscription.current!.daysLeft, 1);
    });

    test('already past the expiry reads as 0, never negative', () async {
      stub(statusBody(
          status: 'expired', periodEnd: iso(const Duration(days: -3))));
      await Subscription.refresh();
      expect(Subscription.current!.daysLeft, 0);
    });

    test('the server\'s own daysLeft is ignored when an expiry is given',
        () async {
      stub(statusBody(
          status: 'active',
          periodEnd: iso(const Duration(days: 5)),
          daysLeft: 999));
      await Subscription.refresh();
      expect(Subscription.current!.daysLeft, 5, reason: 'not 999');
    });
  });

  group('a cached count ages instead of being replayed', () {
    test('a week-old cache reports a week fewer days', () async {
      // Written when 30 days remained, read back 7 days later.
      SharedPreferences.setMockInitialValues({
        'sub_status_v1': jsonEncode({
          'status': 'active',
          'planCode': 'monthly',
          'daysLeft': 30,
          'periodEnd': iso(const Duration(days: 23)),
        }),
      });
      stub(statusBody(status: 'active', periodEnd: iso(const Duration(days: 23))));

      await Subscription.init();

      expect(Subscription.current!.daysLeft, 23,
          reason: 'the stale 30 must not be replayed');
    });

    test('a cache whose expiry has passed reports 0, but does NOT lock out',
        () async {
      SharedPreferences.setMockInitialValues({
        'sub_status_v1': jsonEncode({
          'status': 'active',
          'planCode': 'monthly',
          'daysLeft': 12,
          'periodEnd': iso(const Duration(days: -2)),
        }),
      });
      // Offline: no refresh can correct this.
      Subscription.client = MockClient((_) async => throw const _Offline());

      await Subscription.init();

      expect(Subscription.current!.daysLeft, 0);
      expect(Subscription.current!.expired, isFalse,
          reason: 'only the SERVER may declare an agent expired — a wrong '
              'device clock must never bar a paying agent');
    });

    test('an old cache with no expiry still reports its last known number',
        () async {
      // Written by a build from before periodEnd was stored.
      SharedPreferences.setMockInitialValues({
        'sub_status_v1':
            '{"status":"active","planCode":"monthly","daysLeft":9}',
      });
      Subscription.client = MockClient((_) async => throw const _Offline());

      await Subscription.init();

      expect(Subscription.current!.daysLeft, 9);
    });
  });

  test('the expiry survives a round trip through the cache', () async {
    final end = iso(const Duration(days: 11));
    stub(statusBody(status: 'active', periodEnd: end));
    await Subscription.refresh();

    final p = await SharedPreferences.getInstance();
    final cached = jsonDecode(p.getString('sub_status_v1')!) as Map;
    expect(cached['periodEnd'], end);

    await Subscription.init();
    expect(Subscription.current!.daysLeft, 11);
  });
}

class _Offline implements Exception {
  const _Offline();
}
