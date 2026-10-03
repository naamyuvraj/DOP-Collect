import 'dart:io';

import 'package:dop_collect/services/remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How many phones an account may be signed in on lives in ONE place:
/// `app_config.max_devices`, and WHETHER there is a limit at all lives in
/// `app_config.device_cap`. The `otp` function enforces both and the app words
/// its copy from them, so what the agent is told is always what is in force.
///
/// This used to be "2" typed into six sentences and a server default. Changing
/// it meant changing seven things and hoping — the same shape as the OTP length,
/// which shipped a server that sent codes the app couldn't type.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// [value] is `max_devices`; the cap itself is on unless [capOn] says else.
  Future<void> withConfig(Object? value, {bool capOn = true}) async {
    final parts = <String>[
      if (capOn) '"device_cap": true',
      if (value != null) '"max_devices": $value',
    ];
    SharedPreferences.setMockInitialValues({
      'remote_config_v1': '{${parts.join(", ")}}',
    });
    await RemoteConfig.init();
  }

  group('the cap is off by default', () {
    test('an absent device_cap means no limit is claimed', () async {
      await withConfig(null, capOn: false);
      expect(RemoteConfig.deviceCapOn, isFalse);
      expect(RemoteConfig.devicesPhrase, 'all your phones');
    });

    test('max_devices on its own promises nothing — the cap is what counts',
        () async {
      await withConfig(2, capOn: false);
      expect(RemoteConfig.maxDevices, 2, reason: 'the number is still readable');
      expect(RemoteConfig.devicesPhrase, 'all your phones');
    });

    test('switching the cap back on restores the numbered copy', () async {
      await withConfig(2);
      expect(RemoteConfig.deviceCapOn, isTrue);
      expect(RemoteConfig.devicesPhrase, '2 phones');
    });
  });

  group('the limit', () {
    test('defaults to 3 phones', () async {
      await withConfig(null);
      expect(RemoteConfig.maxDevices, 3);
      expect(RemoteConfig.devicesPhrase, '3 phones');
    });

    test('follows the dashboard', () async {
      await withConfig(5);
      expect(RemoteConfig.maxDevices, 5);
      expect(RemoteConfig.devicesPhrase, '5 phones');
    });

    test('reads a stringified value too — jsonb is not always a number',
        () async {
      await withConfig('"4"');
      expect(RemoteConfig.maxDevices, 4);
    });

    test('one phone is written in the singular', () async {
      await withConfig(1);
      expect(RemoteConfig.devicesPhrase, '1 phone');
    });

    test('a nonsense value falls back rather than locking everyone out',
        () async {
      await withConfig('"banana"');
      expect(RemoteConfig.maxDevices, 3);
    });

    test('is clamped, so a stray keypress cannot set 0 or 900', () async {
      await withConfig(0);
      expect(RemoteConfig.maxDevices, 1, reason: 'never zero — that is a lockout');
      await withConfig(900);
      expect(RemoteConfig.maxDevices, 10);
    });
  });

  test('no screen hardcodes a phone count in its copy', () {
    // The anti-drift guard. If someone types "2 phones" into a sentence again,
    // the config and the copy can disagree the moment the limit changes.
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      // remote_config is where the phrase is DEFINED — the one place allowed
      // to name a number.
      if (f.path.endsWith('remote_config.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('//')) continue; // prose, not shown to anyone
        if (RegExp(r"\b(one|two|three|\d+)[- ]phones?\b", caseSensitive: false)
            .hasMatch(l)) {
          offenders.add('${f.path}:${i + 1}  ${l.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'use RemoteConfig.devicesPhrase instead:\n  '
            '${offenders.join("\n  ")}');
  });
}
