import 'package:dop_collect/data/app_settings.dart';
import 'package:dop_collect/data/credentials.dart';
import 'package:dop_collect/data/session.dart';
import 'package:dop_collect/services/analytics.dart';
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
    Analytics.debugForgetCachedDeviceId();
  });
  tearDown(() => FakeSecureStorage.remove());

  /// What a cold start does: forget the in-process value and read storage.
  Future<String> relaunch() async {
    Analytics.debugForgetCachedDeviceId();
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

  test('a reinstall or "Clear data" DOES mint a new one — the known limit',
      () async {
    // Documented rather than fixed: the id lives in app storage. Wiping it —
    // uninstall/reinstall, "Clear data", or sideloading a build signed with a
    // different key (Android forces an uninstall for that) — makes the SAME
    // phone arrive as a new device and take another slot. Surviving that needs
    // a native identifier, which is a plugin change and so a full release.
    final before = await Analytics.deviceId();
    SharedPreferences.setMockInitialValues({}); // wiped app storage
    final after = await relaunch();

    expect(after, isNot(before));
    expect(after, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });
}
