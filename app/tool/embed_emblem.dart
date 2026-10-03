// Rewrites lib/screens/lists/india_post_emblem.dart with the base64 of
// tool/india_post_logo.png.
//
//   dart run tool/embed_emblem.dart
//
// Run it again whenever the artwork changes. The emblem lives in Dart source
// rather than assets/ so it ships as an OTA patch instead of forcing a release.
import 'dart:convert';
import 'dart:io';

void main() {
  final png = File('tool/india_post_logo.png');
  if (!png.existsSync()) {
    stderr.writeln('tool/india_post_logo.png not found.');
    stderr.writeln('Save the India Post emblem there, then re-run.');
    exitCode = 1;
    return;
  }
  final bytes = png.readAsBytesSync();
  if (bytes.length > 300 * 1024) {
    stderr.writeln('That file is ${(bytes.length / 1024).round()} KB. It gets '
        'compiled into the app and rides in every patch — resize it to about '
        '400px on the long edge first.');
    exitCode = 1;
    return;
  }
  final target = File('lib/screens/lists/india_post_emblem.dart');
  final src = target.readAsStringSync();
  final out = src.replaceFirst(
    RegExp(r"const String indiaPostEmblemBase64 = '[^']*';"),
    "const String indiaPostEmblemBase64 = '${base64Encode(bytes)}';",
  );
  target.writeAsStringSync(out);
  stdout.writeln('Embedded ${(bytes.length / 1024).round()} KB '
      '(${base64Encode(bytes).length} base64 chars).');
}
