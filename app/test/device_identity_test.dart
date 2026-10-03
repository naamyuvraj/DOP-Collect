import 'package:dop_collect/data/app_settings.dart';
import 'package:dop_collect/data/credentials.dart';
import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/services/analytics.dart';
import 'package:dop_collect/services/device_identity.dart';
import 'package:dop_collect/services/subscription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_secure_storage.dart';

/// One phone must count as ONE device, however many times the agent signs in.
///
/// The id in `analytics_device_id` is what the dashboard shows and what the
/// `otp` function keys a session on, so if it changed on sign-out the same
/// phone would occupy a fresh slot every login and an agent would kick
/// themselves off their own account.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FakeSecureStorage.install();
    DeviceIdentity.debugReset();
  });
  tearDown(() => FakeSecureStorage.remove());

  /// What a cold start does: forget the in-process value and read storage.
  Future<String> relaunch() async {
    DeviceIdentity.debugReset();
    return Analytics.deviceId();
  }

  const key = 'analytics_device_id';

  test('the id is generated once and then reused', () async {
    final first = await Analytics.deviceId();
    final again = await Analytics.deviceId();
    expect(again, first);

    final p = await SharedPreferences.getInstance();
    expect(p.getString(key), first, reason: 'it must reach disk, not just RAM');
    expect(first, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });

  test('signing out and back in reuses the same id', () async {
    final before = await Analytics.deviceId();

    // Everything Settings' Logout does, minus the UI and the network.
    await Credentials.clear();
    await SessionStore.clear();
    await Subscription.forget();
    await AppSettings.setOnboarded(false);

    expect(await relaunch(), before,
        reason: 'a re-login on this phone must reuse the same slot, not take '
            'a second one');
  });

  test('it survives a relaunch, read back from storage', () async {
    final before = await Analytics.deviceId();
    expect(await relaunch(), before);
    expect(await relaunch(), before);
  });

  test('changing the mobile number does not change it', () async {
    final before = await Analytics.deviceId();
    await AppSettings.setMobile('9840000004');
    expect(await relaunch(), before);
  });

  test('an app update does not change it — only app STORAGE going away does',
      () async {
    // A Shorebird patch and a Play update both leave app storage alone, so the
    // id rides through. This is the case that matters day to day.
    final before = await Analytics.deviceId();
    final p = await SharedPreferences.getInstance();
    await p.setString('app_version_seen', '0.9.50+30'); // a newer build ran
    expect(await relaunch(), before);
  });

  group('surviving a reinstall', () {
    // The id is derived from ANDROID_ID, which outlives app storage — so a
    // wipe no longer makes the same phone look new.
    const phoneA = {'androidId': 'aaaa1111bbbb2222', 'model': 'Redmi Note 12',
        'manufacturer': 'Xiaomi'};
    const phoneB = {'androidId': 'cccc3333dddd4444', 'model': 'SM-G991B',
        'manufacturer': 'samsung'};

    test('the same phone comes back with the same id', () async {
      DeviceIdentity.debugInfo = Map.of(phoneA);
      final before = await DeviceIdentity.id();

      SharedPreferences.setMockInitialValues({}); // uninstall / Clear data
      DeviceIdentity.debugReset();
      DeviceIdentity.debugInfo = Map.of(phoneA);

      expect(await DeviceIdentity.id(), before,
          reason: 'one phone, one device row — no ghost');
    });

    test('a different phone gets a different id', () async {
      DeviceIdentity.debugInfo = Map.of(phoneA);
      final a = await DeviceIdentity.id();
      SharedPreferences.setMockInitialValues({});
      DeviceIdentity.debugReset();
      DeviceIdentity.debugInfo = Map.of(phoneB);
      expect(await DeviceIdentity.id(), isNot(a));
    });

    test('an id already in storage is never replaced', () async {
      // The migration rule that matters: every existing install has a random
      // uuid. Switching them to a derived one would spawn a second device row
      // for every agent at once — the exact ghosting this is meant to stop.
      const legacy = '01c891c1-1111-4111-a111-111111111111';
      SharedPreferences.setMockInitialValues({key: legacy});
      DeviceIdentity.debugReset();
      DeviceIdentity.debugInfo = Map.of(phoneA);

      expect(await DeviceIdentity.id(), legacy);
    });

    test('a phone that reports nothing still gets a working id', () async {
      DeviceIdentity.debugInfo = const {};
      final id = await DeviceIdentity.id();
      expect(id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(await relaunch(), id, reason: 'random, but still persisted');
    });

    test('the famously broken ANDROID_ID is not trusted', () async {
      // A batch of old devices all report this same literal, so it identifies
      // nothing — those phones must fall back to a random id.
      DeviceIdentity.debugInfo = const {'androidId': '9774d56d682e549c'};
      final a = await DeviceIdentity.id();
      SharedPreferences.setMockInitialValues({});
      DeviceIdentity.debugReset();
      DeviceIdentity.debugInfo = const {'androidId': '9774d56d682e549c'};
      expect(await DeviceIdentity.id(), isNot(a));
    });

    test('the raw ANDROID_ID never becomes the id', () async {
      DeviceIdentity.debugInfo = Map.of(phoneA);
      expect(await DeviceIdentity.id(), isNot(contains('aaaa1111bbbb2222')));
    });
  });

  group('the model name', () {
    test('prefixes the maker when the model does not already carry it',
        () async {
      DeviceIdentity.debugInfo =
          const {'model': 'SM-G991B', 'manufacturer': 'samsung'};
      expect(await DeviceIdentity.modelName(), 'Samsung SM-G991B');
    });

    test('does not repeat a maker the model already names', () async {
      DeviceIdentity.debugInfo =
          const {'model': 'Redmi Note 12', 'manufacturer': 'Redmi'};
      expect(await DeviceIdentity.modelName(), 'Redmi Note 12');
    });

    test('copes with either half missing', () async {
      DeviceIdentity.debugInfo = const {'model': 'Pixel 7'};
      expect(await DeviceIdentity.modelName(), 'Pixel 7');
      DeviceIdentity.debugReset();
      DeviceIdentity.debugInfo = const {'manufacturer': 'oppo'};
      expect(await DeviceIdentity.modelName(), 'Oppo');
      DeviceIdentity.debugReset();
      DeviceIdentity.debugInfo = const {};
      expect(await DeviceIdentity.modelName(), isNull);
    });
  });
}
