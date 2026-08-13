import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the ship commands in the docs, because they are copy-pasted.
///
/// `SupabaseConfig.url` / `anonKey` are `String.fromEnvironment`, so they are
/// baked in at COMPILE time. A build without `--dart-define-from-file=env.json`
/// compiles them to empty strings, `configured` turns false, and every cloud
/// call short-circuits: paywall, OTP, remote config, analytics and the cloud
/// assistant all go quiet at once. Nothing throws and nothing logs — screens
/// just come up blank, which is exactly how it reached production once.
///
/// A test can't stop someone typing the wrong command, but it can stop the
/// wrong command from living in the runbook they copy from.
void main() {
  final docs = ['RUNBOOK.md', 'README.md'];

  /// Build lines that actually compile Dart into the app.
  Iterable<String> buildCommandsIn(String path) sync* {
    for (final raw in File(path).readAsLinesSync()) {
      final line = raw.trim();
      if (line.startsWith('#') || line.startsWith('>')) continue; // prose
      final isBuild = line.startsWith('shorebird patch') ||
          line.startsWith('shorebird release') ||
          line.startsWith('flutter build apk') ||
          line.startsWith('flutter build appbundle');
      if (isBuild) yield line;
    }
  }

  for (final doc in docs) {
    test('$doc: every build command passes the Supabase dart-defines', () {
      final file = File(doc);
      if (!file.existsSync()) return;

      final missing = buildCommandsIn(doc)
          .where((c) => !c.contains('--dart-define-from-file=env.json'))
          .toList();

      expect(missing, isEmpty,
          reason: 'these ship an app with no Supabase config — every cloud '
              'feature dies silently:\n  ${missing.join("\n  ")}');
    });
  }

  test('the runbook documents at least one way to ship', () {
    // Keeps the check above honest: if the commands are ever renamed or moved,
    // this fails rather than letting the guard pass over an empty list.
    expect(buildCommandsIn('RUNBOOK.md'), isNotEmpty);
  });

  test('env.json.example carries both keys the build needs', () {
    final example = File('env.json.example');
    if (!example.existsSync()) return;
    final text = example.readAsStringSync();
    expect(text, contains('SUPABASE_URL'));
    expect(text, contains('SUPABASE_ANON_KEY'));
  });
}
