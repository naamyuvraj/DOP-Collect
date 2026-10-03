import 'dart:convert';

import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/services/otp_service.dart';
import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_secure_storage.dart';

/// The client half of the S1 fix.
///
/// The server now refuses a `changePhone` verify unless it carries a live
/// session token proving the caller already owns the account. That is only a
/// fix if the app actually SENDS the token — otherwise the legitimate
/// "update my number" flow 403s for everyone. These tests read the real
/// request body off the wire.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> sent;
  late List<Map<String, String>> headers;

  /// Answers every request with [reply]; records what was posted.
  void stub(Map<String, dynamic> reply, {int status = 200}) {
    OtpService.client = MockClient((req) async {
      sent.add(jsonDecode(req.body) as Map<String, dynamic>);
      headers.add(req.headers);
      return http.Response(jsonEncode(reply), status,
          headers: {'content-type': 'application/json'});
    });
  }

  setUp(() async {
    sent = [];
    headers = [];
    SharedPreferences.setMockInitialValues({});
    // A real read/write round trip, so a session that never actually persisted
    // can't pass by sitting in SessionStore's in-process cache.
    FakeSecureStorage.install();
    SupabaseConfig.testUrl = 'https://fake.supabase.test';
    SupabaseConfig.testAnonKey = 'anon-key-test';
    await SessionStore.clear();
  });

  tearDown(() async {
    SupabaseConfig.testUrl = null;
    SupabaseConfig.testAnonKey = null;
    await SessionStore.clear();
    OtpService.client = http.Client();
    FakeSecureStorage.remove();
  });

  group('changePhone carries the session token', () {
    test('the token from THIS device is put on the wire', () async {
      await SessionStore.save(
          const Session('live-token-abc', 'acct-1', '9810000001', 'AGENT-1'));
      stub({'ok': true, 'token': 'new-token', 'accountId': 'acct-1'});

      await OtpService.verify('9840000004', '1234',
          agentId: 'AGENT-1', changePhone: true);

      expect(sent.single['action'], 'verify');
      expect(sent.single['changePhone'], true);
      expect(sent.single['token'], 'live-token-abc',
          reason: 'without this the server returns reauth_required');
    });

    test('an ordinary verify sends no token — there is nothing to prove yet',
        () async {
      stub({'ok': true, 'token': 'issued', 'accountId': 'acct-9'});

      await OtpService.verify('9850000005', '1234', agentId: 'AGENT-NEW');

      expect(sent.single.containsKey('changePhone'), isFalse);
      expect(sent.single.containsKey('token'), isFalse);
    });

    test('a changePhone with no session on the device sends no token',
        () async {
      // Nothing to prove ownership with — the server will (correctly) refuse.
      stub({'ok': false, 'code': 'reauth_required'}, status: 403);

      final r = await OtpService.verify('9840000004', '1234',
          agentId: 'AGENT-1', changePhone: true);

      expect(sent.single['changePhone'], true);
      expect(sent.single.containsKey('token'), isFalse);
      expect(r.ok, isFalse);
      expect(r.code, 'reauth_required');
    });
  });

  group('the request itself', () {
    test('carries the anon key on both auth headers', () async {
      stub({'ok': true});
      await OtpService.send('9810000001');
      expect(headers.single['apikey'], 'anon-key-test');
      expect(headers.single['Authorization'], 'Bearer anon-key-test');
    });

    test('a stable device id is sent so the server can rate-limit', () async {
      stub({'ok': true});
      await OtpService.send('9810000001');
      await OtpService.send('9810000001', resend: true);
      final a = sent[0]['deviceId'] as String;
      expect(a, isNotEmpty);
      expect(sent[1]['deviceId'], a, reason: 'must not rotate per call');
      expect(sent[1]['action'], 'resend');
    });
  });

  group('outcomes', () {
    test('a successful verify stores the session for later calls', () async {
      stub({'ok': true, 'token': 'tok-xyz', 'accountId': 'acct-7'});

      final r = await OtpService.verify('9860000006', '1234',
          agentId: 'AGENT-7');

      expect(r.ok, isTrue);
      final s = await SessionStore.load();
      expect(s, isNotNull);
      expect(s!.token, 'tok-xyz');
      expect(s.accountId, 'acct-7');
      expect(s.agentId, 'AGENT-7');
      expect(s.phone, '9860000006');
      // ...and it really reached the Keystore, not just the in-memory cache.
      expect(FakeSecureStorage.values['otp_session_token'], 'tok-xyz');
    });

    test('reauth_required explains itself in words the agent can act on',
        () async {
      stub({'ok': false, 'code': 'reauth_required'}, status: 403);
      final r = await OtpService.verify('9840000004', '1234',
          agentId: 'AGENT-1', changePhone: true);
      expect(r.ok, isFalse);
      expect(r.message, contains('already signed in'));
    });

    test('a failed verify does NOT leave a session behind', () async {
      stub({'ok': false, 'code': 'invalid_otp'}, status: 401);
      await OtpService.verify('9860000006', '9999', agentId: 'AGENT-7');
      expect(await SessionStore.load(), isNull);
    });

    test('a network failure reads as offline, not as a wrong code', () async {
      OtpService.client = MockClient((_) async => throw const SocketFail());
      final r = await OtpService.verify('9860000006', '1234', agentId: 'A');
      expect(r.code, 'network');
      expect(r.message, contains('No connection'));
    });

    test('logout revokes server-side and clears the local token', () async {
      await SessionStore.save(
          const Session('tok-1', 'acct-1', '9810000001', 'AGENT-1'));
      stub({'ok': true});

      await OtpService.logout();

      expect(sent.single['action'], 'logout');
      expect(sent.single['token'], 'tok-1');
      expect(await SessionStore.load(), isNull);
    });

    test('the heartbeat fails OPEN when the server is unreachable', () async {
      await SessionStore.save(
          const Session('tok-1', 'acct-1', '9810000001', 'AGENT-1'));
      OtpService.client = MockClient((_) async => throw const SocketFail());
      expect(await OtpService.sessionValid(), isTrue,
          reason: 'a network blip must never sign a working agent out');
    });

    test('the heartbeat signs out when the server says the session is gone',
        () async {
      await SessionStore.save(
          const Session('tok-1', 'acct-1', '9810000001', 'AGENT-1'));
      stub({'ok': false, 'reason': 'device_limit'});
      expect(await OtpService.sessionValid(), isFalse);
    });
  });
}

class SocketFail implements Exception {
  const SocketFail();
}
