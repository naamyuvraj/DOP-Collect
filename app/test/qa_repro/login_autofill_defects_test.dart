import 'dart:io';

import 'package:dop_collect/data/credentials.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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

/// A SharedPreferences store that fails every call.
///
/// `Credentials.load()` used to read prefs ABOVE its try/catch, so a failure
/// here escaped a method whose entire contract is that it never throws. That
/// mattered more after C3: `_credsReady` is now a dependency of the captcha
/// solve as well as the autofill, so an errored future would take both down.
class _BrokenPrefs extends SharedPreferencesStorePlatform {
  @override
  Future<bool> clear() => throw StateError('prefs unavailable');
  @override
  Future<Map<String, Object>> getAll() => throw StateError('prefs unavailable');
  @override
  Future<bool> remove(String key) => throw StateError('prefs unavailable');
  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      throw StateError('prefs unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _Keystore.install({'agent_id': 'AG12345', 'agent_pw': 's3cret'});
  });
  tearDown(_Keystore.remove);

  // ───────────────────────────────────────────────────────────────────────────
  group('DEFECT C1 (FIXED) — the auto-login budget is gone', () {
    /// The counter was a per-CALENDAR-DAY allowance of four. Ordinary work
    /// spent it — Sync, Prepare, Submit, Deep Sync is four screens — so a
    /// perfectly healthy agent could open a fifth screen in the afternoon and
    /// be told "daily auto-login limit reached. Tap Login." over nothing that
    /// had ever failed. It is removed: the stored key, the counters, the gate
    /// and the message.
    ///
    /// Source-level, because the guarantee is "no code path rations logins by
    /// the day", which is a statement about the files rather than about any one
    /// run of them.
    /// Comments explain what was removed and why, so they legitimately quote
    /// the old names. Assert against CODE.
    String code(String path) => File(path)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    final screen = code('lib/screens/portal/sync_screen.dart');
    final settings = code('lib/data/app_settings.dart');

    test('nothing counts logins by the day any more', () {
      expect(settings.contains('AutoLoginCount'), isFalse);
      expect(settings.contains('dop_auto_login_'), isFalse,
          reason: 'no stored allowance means none to run out mid-collection');
      expect(screen.contains('dailyAutoLoginCount'), isFalse);
      expect(screen.contains('daily auto-login limit'), isFalse,
          reason: 'the message that told him to give up must be gone too');
    });

    test('the app still logs in by itself', () {
      expect(screen.contains('_clickLoginAndJudge'), isTrue);
      expect(screen.contains('VALIDATE_CREDENTIALS'), isTrue,
          reason: 'it presses the portal\'s own Log in button');
      expect(screen.contains('_submitAfterHumanCheck'), isTrue,
          reason: 'and still finishes the job once a reCAPTCHA is passed');
    });

    test('the one remaining stop is per SCREEN, and clears on success', () {
      // Four rejected submits on one screen. Not persisted, not per-day, and
      // reset to 0 the moment a login is accepted — including a manual one.
      expect(screen.contains('if (_loginClicks < 4)'), isTrue);
      expect(screen.contains('_loginClicks = 0;'), isTrue);
      // It must never reach disk. That is exactly what made the old one a
      // budget rather than a loop-stopper.
      expect(RegExp(r'setInt\([^)]*_loginClicks').hasMatch(screen), isFalse);
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
  group('C3 (FIXED) — the captcha solve waits for the Keystore', () {
    // The race is unchanged and unfixable at this level: load() really is a
    // multi-hop platform round trip, and the login page really can finish
    // first. What changed is that the captcha solve no longer STARTS on a wall
    // clock — it is chained behind _credsReady — and that losing the race is no
    // longer permanent.

    test('the race is real: load() is a multi-hop platform round trip',
        () async {
      await Credentials.load();
      expect(_Keystore.reads, greaterThanOrEqualTo(2),
          reason: 'two Keystore reads (id + password) on top of a '
              'SharedPreferences load and a plaintext-migration pass. This is '
              'why a fixed 900ms timer could never be the right answer.');
      // ignore: avoid_print
      print('    C3: ${_Keystore.reads} Keystore reads per load()');
    });

    test('load() still never throws when the KEYSTORE fails', () async {
      _Keystore.throwOnRead = true;
      final c = await Credentials.load();
      expect(c.hasAny, isFalse);
    });

    test('load() never throws when the PREFS STORE fails either', () async {
      // The one path that still escaped: the prefs read sat above the try.
      // getInstance() caches, so the cache has to go too or the broken store is
      // never reached and this test proves nothing.
      final good = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _BrokenPrefs();
      addTearDown(() {
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = good;
      });
      // Proof the store really is broken from here.
      await expectLater(SharedPreferences.getInstance(), throwsStateError);

      // And that load() absorbs it. An uncaught throw fails this test.
      final c = await Credentials.load();
      expect(c.hasAny, isFalse,
          reason: 'degraded to empty credentials, not an errored future — '
              '_credsReady now gates the captcha solve as well as the '
              'autofill, so a throw here would take both down');
    });

    test('load() answers within the 8s budget the screen allows it', () async {
      // _loadCredentials() times out at 8s so a wedged Keystore (direct boot, a
      // stuck vendor provider) cannot leave _credsReady unresolved forever and
      // the captcha solve waiting behind it.
      final started = DateTime.now();
      await Credentials.load().timeout(const Duration(seconds: 8));
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 8)));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('C3 (FIXED) — the shape of the fix, read out of the source', () {
    // SyncScreen cannot be widget-tested here: it pulls in the SQLCipher-backed
    // AccountRepository and a WebViewWidget platform. These read the shipping
    // source instead — the same trick test/qa_repro/js/extract.js uses — so the
    // ordering cannot silently revert to a wall-clock timer.
    final src = File('lib/screens/portal/sync_screen.dart').readAsStringSync();

    test('the captcha solve is not armed on a wall-clock timer', () {
      expect(src, isNot(contains('Duration(milliseconds: 900)')),
          reason: 'the 900ms timer that raced the Keystore read is gone');
      expect(src, contains('unawaited(_armCaptchaSolve());'),
          reason: 'page-finish arms the chained path instead');
    });

    test('_armCaptchaSolve fills the credentials BEFORE reading the captcha',
        () {
      final body = src.substring(src.indexOf('Future<void> _armCaptchaSolve()'));
      final fill = body.indexOf('_autofillIfLogin()');
      final solve = body.indexOf('_autofillCaptcha()');
      expect(fill, greaterThan(-1));
      expect(solve, greaterThan(-1));
      expect(fill, lessThan(solve),
          reason: 'the credentials must be typed first — that ordering is the '
              'whole fix');
      expect(body.substring(fill - 20, fill), contains('await'),
          reason: 'and it must be awaited, or it is the same race again');
    });

    test('the credential gate re-arms instead of surrendering', () {
      expect(src, contains('Future<bool> _ensureCredsInForm()'));
      final gate =
          src.substring(src.indexOf('Future<bool> _ensureCredsInForm()'));
      expect(gate.substring(0, gate.indexOf('\n  }')),
          allOf(contains('await _credsReady'), contains('_autofillIfLogin()')),
          reason: 'an empty form waits for the Keystore and types again before '
              'handing the screen back — the old path just returned');
    });

    test('_credsReady is built from a future that cannot throw', () {
      expect(src, contains('_credsReady = _loadCredentials();'));
      expect(src, isNot(contains('_credsReady = Credentials.load()')),
          reason: 'the raw future was assignable to _credsReady and could '
              'error; _loadCredentials() catches and times out');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('A1 (FIXED) — auto-start polls instead of probing once', () {
    // Same limitation as C3: SyncScreen cannot be widget-tested here, so the
    // shape is read out of the shipping source. A1 was the one finding in the
    // original audit that was never reproduced at all — inferred from the code
    // and rated High on reasoning. These at least stop it reverting silently.
    final src = File('lib/screens/portal/sync_screen.dart').readAsStringSync();

    test('the single unsettled probe is gone', () {
      expect(src, isNot(contains('(A1: probed once, no settle)')),
          reason: 'the trace string that documented the defect');
      expect(src, contains('Future<bool> _pollAuthenticated()'));
    });

    test('the poll settles before its first read', () {
      final body = src.substring(src.indexOf('Future<bool> _pollAuthenticated()'));
      final poll = body.substring(0, body.indexOf('\n  }'));
      final delay = poll.indexOf('await Future<void>.delayed');
      final read = poll.indexOf('_engine.isAuthenticated()');
      expect(delay, greaterThan(-1), reason: 'no settle at all');
      expect(delay, lessThan(read),
          reason: 'every other DOM read in the engine settles first; this one '
              'fired straight off onPageFinished, which is document-load time');
    });

    test('the poll is bounded, and gives up early on the login form', () {
      final body = src.substring(src.indexOf('Future<bool> _pollAuthenticated()'));
      final poll = body.substring(0, body.indexOf('\n  }'));
      expect(poll, contains('deadline'),
          reason: 'an unbounded poll on every page-finish is a battery bug');
      expect(poll, contains('_onLoginPageJs'),
          reason: 'a page still showing the password box is not going to '
              'become authenticated by asking it eight more times');
    });

    test('only one poll runs at a time', () {
      expect(src, contains('_autoStartPolling'),
          reason: '_maybeAutoStart fires on every page-finish and the poll '
              'outlives the callback that started it');
      final body = src.substring(src.indexOf('Future<void> _maybeAutoStart()'));
      expect(body.substring(0, body.indexOf('\n  }')),
          contains('_autoStartPolling) return'));
    });
  });
}
