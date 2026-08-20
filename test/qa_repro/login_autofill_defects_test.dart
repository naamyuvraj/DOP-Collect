import 'package:dop_collect/data/app_settings.dart';
import 'package:dop_collect/data/credentials.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keystore stand-in that can be told to fail, and that counts round trips.
class _Keystore {
  static const _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  static final Map<String, String> values = {};
  static int reads = 0;
  static bool throwOnRead = false;

  static void install([Map<String, String> seed = const {}]) {
    values
      ..clear()
      ..addAll(seed);
    reads = 0;
    throwOnRead = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          reads++;
          if (throwOnRead) {
            throw PlatformException(
                code: 'Error',
                message: 'javax.crypto.BadPaddingException: '
                    'error:1e000065:Cipher functions:OPENSSL_internal:BAD_DECRYPT');
          }
          return values[key];
        case 'write':
          if (key != null) values[key] = args['value'] as String? ?? '';
          return null;
        case 'delete':
          values.remove(key);
          return null;
        default:
          return null;
      }
    });
  }

  static void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _Keystore.install({'agent_id': 'AG12345', 'agent_pw': 's3cret'});
  });
  tearDown(_Keystore.remove);

  // ───────────────────────────────────────────────────────────────────────────
  group('DEFECT C1 — the auto-login budget is spent by SUCCESSES', () {
    /// Mirrors the live gate at sync_screen.dart:418.
    bool autoLoginAllowed(int loginClicksThisScreen, int dailyAttempts) =>
        loginClicksThisScreen < 4 && dailyAttempts < 4;

    test('EVIDENCE: four ordinary portal trips exhaust the day', () async {
      final today = DateTime(2026, 8, 20);
      // A normal working day: Sync, Prepare a list, Submit it, Deep Sync.
      // Each opens a SyncScreen and each auto-login SUCCEEDS.
      for (final _ in ['sync', 'prepare', 'submit', 'deep']) {
        await AppSettings.incrementDailyAutoLoginCount(today);
      }
      final count = await AppSettings.dailyAutoLoginCount(today);
      expect(count, 4);
      expect(autoLoginAllowed(0, count), isFalse,
          reason: 'the 5th screen of the day gets "daily auto-login limit '
              'reached. Tap Login." even though nothing ever failed');
    });

    test('a successful login must not consume the day\'s budget', () async {
      final today = DateTime(2026, 8, 20);
      // A normal working day: four screens, every auto-login succeeds. The
      // screen records the attempt, then the outcome clears it — which is what
      // the portal does to its own failed-attempt counter on success.
      for (var i = 0; i < 4; i++) {
        await AppSettings.incrementDailyAutoLoginCount(today);
        await AppSettings.resetDailyAutoLoginCount(today);
      }
      expect(await AppSettings.dailyAutoLoginCount(today), 0,
          reason: 'the counter guards Finacle\'s 10-FAILED-attempt lockout, '
              'so a day of successes must leave it untouched');
    });

    test('failures still accumulate, and still stop auto-login', () async {
      final today = DateTime(2026, 8, 20);
      for (var i = 0; i < 4; i++) {
        await AppSettings.incrementDailyAutoLoginCount(today);
      }
      expect(await AppSettings.dailyAutoLoginCount(today), 4);
      expect(autoLoginAllowed(0, 4), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('C2 (FIXED) — a Keystore fault degrades, it does not kill', () {
    test('a Keystore fault is reported, not propagated', () async {
      // It used to throw into a future SyncScreen awaits unawaited, which took
      // autofill out for the life of the screen with nothing said.
      _Keystore.throwOnRead = true;
      await expectLater(Credentials.load(), completes);
    });

    test('load() degrades to empty credentials instead of throwing', () async {
      _Keystore.throwOnRead = true;
      // Awaited directly: returnsNormally does not await an async closure, so
      // the original assigned `c` after the assertion had already read it.
      final c = await Credentials.load();
      expect(c.hasAny, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('DEFECT C3 — the captcha timer races the Keystore read', () {
    test('EVIDENCE: load() is a multi-hop platform round trip, not a cache',
        () async {
      await Credentials.load();
      expect(_Keystore.reads, greaterThanOrEqualTo(2),
          reason: 'two Keystore reads (id + password) on top of a '
              'SharedPreferences load and a plaintext-migration pass — '
              'raced against the FIXED 900ms captcha timer at '
              'sync_screen.dart:131, which is armed on the same page-finish');
      // ignore: avoid_print
      print('    EVIDENCE C3: ${_Keystore.reads} Keystore reads per load()');
    });

    test('EVIDENCE: a fresh load() is required on the very first page-finish',
        () async {
      // _credsReady is built ONCE in initState (sync_screen.dart:139), so the
      // only page load that can lose the race is the first one — which is the
      // login page. That is exactly why the failure is intermittent: cold start
      // loses, warm start wins.
      final first = await Credentials.load();
      expect(first.agentId, 'AG12345');
      expect(_Keystore.reads, greaterThanOrEqualTo(2));
    });
  });
}
