import 'dart:convert';

import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/services/remote_config.dart';
import 'package:dop_collect/services/subscription.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_secure_storage.dart';

/// The client half of the S7 fix.
///
/// `pay` now derives the agent id from the session token and 401s without one.
/// So the app must send the token on every call — and must not bother calling
/// at all when there is no session, or a startup with OTP off would fire a
/// pointless request per launch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> sent;
  late Map<String, dynamic> reply;

  void stub({int status = 200}) {
    Subscription.client = MockClient((req) async {
      sent.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(jsonEncode(reply), status,
          headers: {'content-type': 'application/json'});
    });
  }

  const okStatus = {
    'ok': true,
    'status': 'active',
    'planCode': 'm1',
    'daysLeft': 30,
    'plans': [
      {'code': 'm1', 'name': 'Monthly', 'price_inr': 199, 'duration_days': 30},
    ],
  };

  setUp(() async {
    sent = [];
    reply = Map<String, dynamic>.from(okStatus);
    SharedPreferences.setMockInitialValues({});
    // A signed-in DOP agent, so purchase() gets past its credentials guard.
    FakeSecureStorage.install({'agent_id': 'AGENT-1', 'agent_pw': 'pw'});
    SupabaseConfig.testUrl = 'https://fake.supabase.test';
    SupabaseConfig.testAnonKey = 'anon-key-test';
    await SessionStore.clear();
    await Subscription.forget();
    stub();
  });

  tearDown(() async {
    SupabaseConfig.testUrl = null;
    SupabaseConfig.testAnonKey = null;
    await SessionStore.clear();
    await Subscription.forget();
    Subscription.client = http.Client();
    Subscription.opener = null;
    FakeSecureStorage.remove();
  });

  Future<void> signedIn() => SessionStore.save(
      const Session('sess-token-1', 'acct-1', '9810000001', 'AGENT-1'));

  group('the session token gates the call', () {
    test('no session — status still runs, so the paywall can show prices',
        () async {
      // Bailing out before the request left the paywall blank behind a Retry
      // button that could never succeed. Prices are public; entitlement is not.
      reply = {
        'ok': true, 'status': 'unknown', 'planCode': '', 'daysLeft': 0,
        'plans': [
          {'code': 'm1', 'name': 'Monthly', 'price_inr': 199, 'duration_days': 30},
        ],
      };

      await Subscription.refresh();

      expect(sent.single['action'], 'status');
      expect(sent.single.containsKey('token'), isFalse, reason: 'none to send');
      expect(Subscription.current?.plans.length, 1,
          reason: 'the paywall needs a plan list to render');
      expect(Subscription.current?.status, 'unknown');
      expect(Subscription.blocked, isFalse);
    });

    test('an unknown answer never overwrites a known plan', () async {
      await signedIn();
      await Subscription.refresh();
      expect(Subscription.current?.status, 'active');

      // The session goes away (kicked by the device limit, say).
      await SessionStore.clear();
      reply = {
        'ok': true, 'status': 'unknown', 'planCode': '', 'daysLeft': 0,
        'plans': [
          {'code': 'm1', 'name': 'Monthly', 'price_inr': 199, 'duration_days': 30},
        ],
      };
      await Subscription.refresh();

      expect(Subscription.current?.status, 'active',
          reason: 'a non-answer must not downgrade a known entitlement');
      expect(Subscription.current?.plans.length, 1, reason: 'prices refreshed');
    });

    test('an unknown answer is not written over a cached real one', () async {
      await signedIn();
      await Subscription.refresh();
      final p = await SharedPreferences.getInstance();
      expect(p.getString('sub_status_v1'), contains('active'));

      await SessionStore.clear();
      reply = {
        'ok': true, 'status': 'unknown', 'planCode': '', 'daysLeft': 0,
        'plans': const [],
      };
      await Subscription.refresh();

      expect(p.getString('sub_status_v1'), contains('active'),
          reason: 'next cold start must not boot into a non-answer');
    });

    test('every call carries the token', () async {
      await signedIn();
      await Subscription.refresh();
      expect(sent.single['action'], 'status');
      expect(sent.single['token'], 'sess-token-1');
    });

    test('identity is NOT claimed by agent id any more', () async {
      await signedIn();
      await Subscription.refresh();
      expect(sent.single.containsKey('agentId'), isFalse,
          reason: 'the server derives it from the token; sending it invites '
              'the reader to think it still means something');
    });
  });

  group('status', () {
    test('a fresh status is applied and cached', () async {
      await signedIn();
      await Subscription.refresh();
      expect(Subscription.current?.status, 'active');
      expect(Subscription.current?.planCode, 'm1');
      expect(Subscription.current?.daysLeft, 30);
      expect(Subscription.current?.plans.length, 1);

      final p = await SharedPreferences.getInstance();
      expect(p.getString('sub_status_v1'), contains('active'));
    });

    test('an expired plan blocks only once payments are switched on', () async {
      await signedIn();
      reply = {...okStatus, 'status': 'expired', 'daysLeft': 0};

      SharedPreferences.setMockInitialValues(
          {'remote_config_v1': '{"payments_enabled": false}'});
      await RemoteConfig.init();
      await Subscription.refresh();
      expect(Subscription.current?.expired, isTrue);
      expect(Subscription.blocked, isFalse, reason: 'paywall is off');

      SharedPreferences.setMockInitialValues(
          {'remote_config_v1': '{"payments_enabled": true}'});
      await RemoteConfig.init();
      expect(Subscription.blocked, isTrue);
    });

    test('a server error leaves the previous status alone', () async {
      await signedIn();
      await Subscription.refresh();
      expect(Subscription.current?.status, 'active');

      reply = {'ok': false, 'error': 'rate_limited'};
      await Subscription.refresh();
      expect(Subscription.current?.status, 'active',
          reason: 'a bad response must not downgrade a paying agent');
    });

    test('an unreachable server leaves the previous status alone', () async {
      await signedIn();
      await Subscription.refresh();
      Subscription.client = MockClient((_) async => throw const NetFail());
      await Subscription.refresh();
      expect(Subscription.current?.status, 'active');
      expect(Subscription.blocked, isFalse);
    });
  });

  group('purchase', () {
    /// Order -> checkout sheet -> verify -> status refresh.
    void stubPurchase() {
      var call = 0;
      Subscription.client = MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        call++;
        final out = call == 1
            ? {
                'ok': true, 'orderId': 'order_1', 'keyId': 'rzp_test',
                'amount': 19900, 'planName': 'Monthly',
              }
            : call == 2
                ? {'ok': true, 'status': 'active'}
                : okStatus;
        return http.Response(jsonEncode(out), 200,
            headers: {'content-type': 'application/json'});
      });
    }

    test('order and verify both carry the token, and claim no agent id',
        () async {
      await signedIn();
      Subscription.opener =
          (order) async => RazorpayResult(order.orderId, 'pay_1', 'sig_1');
      stubPurchase();

      expect(await Subscription.purchase('m1'), isTrue);

      expect(sent[0]['action'], 'order');
      expect(sent[0]['planCode'], 'm1');
      expect(sent[0]['token'], 'sess-token-1');
      expect(sent[0].containsKey('agentId'), isFalse);

      expect(sent[1]['action'], 'verify');
      expect(sent[1]['token'], 'sess-token-1');
      expect(sent[1]['orderId'], 'order_1');
      expect(sent[1]['paymentId'], 'pay_1');
      expect(sent[1]['signature'], 'sig_1');
      expect(sent[1].containsKey('agentId'), isFalse);

      // ...and the entitlement is re-read, so the gate clears immediately.
      expect(sent[2]['action'], 'status');
      expect(Subscription.current?.status, 'active');
    });

    test('the amount the sheet is opened with comes from the SERVER',
        () async {
      await signedIn();
      RazorpayOrder? opened;
      Subscription.opener = (order) async {
        opened = order;
        return RazorpayResult(order.orderId, 'pay_1', 'sig_1');
      };
      stubPurchase();

      await Subscription.purchase('m1');

      expect(opened, isNotNull);
      expect(opened!.amount, 19900, reason: 'never a client-side price');
      expect(opened!.orderId, 'order_1');
      expect(opened!.keyId, 'rzp_test');
    });

    test('a cancelled sheet verifies nothing', () async {
      await signedIn();
      Subscription.opener = (_) async => null; // user backed out
      stubPurchase();

      expect(await Subscription.purchase('m1'), isFalse);
      expect(sent.length, 1, reason: 'only the order was created');
      expect(sent.single['action'], 'order');
    });

    test('no session — the order is refused and nothing is charged', () async {
      Subscription.opener =
          (order) async => RazorpayResult(order.orderId, 'p', 's');
      // What the server really answers for `order` without a token.
      Subscription.client = MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('{"ok":false,"error":"unauthorized"}', 401,
            headers: {'content-type': 'application/json'});
      });

      expect(await Subscription.purchase('m1'), isFalse);
      expect(sent.single['action'], 'order');
      expect(Subscription.lastError, contains('unauthorized'),
          reason: 'the agent should be told why, not left staring at a sheet');
    });

    test('without a DOP login the flow stops before any network call',
        () async {
      FakeSecureStorage.install(); // no agent_id
      await signedIn();
      stubPurchase();
      expect(await Subscription.purchase('m1'), isFalse);
      expect(Subscription.lastError, contains('agent id'));
      expect(sent, isEmpty);
    });
  });

  group('forget()', () {
    test('clears memory, disk, and notifies the gate', () async {
      await signedIn();
      await Subscription.refresh();
      expect(Subscription.current, isNotNull);

      var notified = false;
      Subscription.onChanged = () => notified = true;
      await Subscription.forget();
      Subscription.onChanged = null;

      expect(Subscription.current, isNull);
      expect(notified, isTrue, reason: 'the root gate must re-evaluate');
      final p = await SharedPreferences.getInstance();
      expect(p.getString('sub_status_v1'), isNull);
    });
  });
}

class NetFail implements Exception {
  const NetFail();
}
