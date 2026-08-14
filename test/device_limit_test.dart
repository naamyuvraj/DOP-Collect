import 'dart:io';

import 'package:dop_collect/services/remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How many phones an account may be signed in on lives in ONE place:
/// `app_config.max_devices`. The `otp` function enforces it and the app words
/// its copy from it, so the number the agent is told is always the number in
/// force.
///
/// This used to be "2" typed into six sentences and a server default. Changing
/// it meant changing seven things and hoping — the same shape as the OTP length,
/// which shipped a server that sent codes the app couldn't type.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> withConfig(Object? value) async {
    SharedPreferences.setMockInitialValues({
      'remote_config_v1': value == null ? '{}' : '{"max_devices": $value}',
    });
    await RemoteConfig.init();
  }

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
