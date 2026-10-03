import 'dart:io';

import 'package:dop_collect/services/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// `SupabaseConfig.buildVersion` is what a running install REPORTS — it drives
/// the dashboard's patched-vs-unpatched view and the force-update comparison.
/// `pubspec.yaml` is what a Shorebird RELEASE is cut from.
///
/// The two have to move differently, and getting it wrong fails silently:
///   * an OTA patch bumps the build number here ONLY (+22 -> +23) and leaves
///     pubspec pinned, because the patch attaches to that release;
///   * a new release bumps both together.
///
/// Ship a patch without bumping this and every patched device keeps reporting
/// the old number, so the rollout is invisible. Bump the SEMANTIC part without
/// cutting a release and the version the app reports no longer corresponds to
/// any release at all.
void main() {
  ({String semver, int build}) parse(String v) {
    final parts = v.split('+');
    return (semver: parts.first, build: int.parse(parts.last));
  }

  late String pubspecVersion;

  setUpAll(() {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    pubspecVersion = line.split(':').last.trim();
  });

  test('buildVersion is a full major.minor.patch+build string', () {
    expect(SupabaseConfig.buildVersion, matches(r'^\d+\.\d+\.\d+\+\d+$'));
  });

  test('the semantic version matches the release in pubspec', () {
    expect(
      parse(SupabaseConfig.buildVersion).semver,
      parse(pubspecVersion).semver,
      reason: 'a patch must stay attached to its release — bump the build '
          'number only, or cut a new release and move both',
    );
  });

  test('the reported build number is never BEHIND the release', () {
    final reported = parse(SupabaseConfig.buildVersion).build;
    final release = parse(pubspecVersion).build;
    expect(reported, greaterThanOrEqualTo(release),
        reason: 'an install cannot report an older build than it was cut from');
  });

  test('a patch ahead of the release is fine — that IS the patch marker', () {
    // Documents the intended shape rather than pinning today's numbers, so this
    // file does not need editing on every patch.
    expect(parse('0.9.50+23').build, greaterThan(parse('0.9.50+22').build));
    expect(parse('0.9.50+23').semver, parse('0.9.50+22').semver);
  });
}
