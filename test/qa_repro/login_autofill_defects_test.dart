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
      for (var i = 0; i < 4; i++) {
        await AppSettings.incrementDailyAutoLoginCount(today);
        // …and each one SUCCEEDED, which on the portal side resets its own
        // failed-attempt counter. Nothing in the app records that.
      }
      expect(await AppSettings.dailyAutoLoginCount(today), 0,
          reason: 'DEFECT C1: the counter guards Finacle\'s 10-FAILED-attempt '
              'lockout, but it counts successes and is never reset');
    },
        skip: 'DEFECT C1 — un-skip once only failed attempts are counted '
            'and a success clears the day');
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('DEFECT C2 — a Keystore fault kills autofill silently', () {
    test('EVIDENCE: Credentials.load() propagates the platform exception',
        () async {
      _Keystore.throwOnRead = true;
      await expectLater(Credentials.load(), throwsA(isA<PlatformException>()));
    });

    test('load() degrades to empty credentials instead of throwing', () async {
      _Keystore.throwOnRead = true;
      late Credentials c;
      await expectLater(
          () async => c = await Credentials.load(), returnsNormally);
      expect(c.hasAny, isFalse);
    },
        skip: 'DEFECT C2 — un-skip once Credentials.load() catches and reports '
            'a Keystore fault (sync_screen.dart:139 stores the errored future '
            'in _credsReady, and :128 awaits it unawaited -> unhandled async '
            'error, autofill dead for the life of the screen, no message)');
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
