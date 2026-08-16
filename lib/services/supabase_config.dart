import 'package:flutter/foundation.dart' show visibleForTesting;

/// Supabase analytics configuration.
///
/// PASTE your Project URL + **anon (public)** key below (Supabase -> Settings ->
/// API). The anon key is safe to ship — RLS only lets it INSERT telemetry, never
/// read. Leave both blank to disable analytics entirely (nothing is sent).
///
/// You can also pass them at build time instead of hardcoding:
///   flutter build ... --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class SupabaseConfig {
  static const String _envUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const String _envAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// Test seam. The real values are compile-time `--dart-define`s, so they are
  /// always blank under `flutter test` and every network client short-circuits
  /// on [configured] — which would make the request-building code (auth
  /// headers, the session token) untestable. Setting these points the clients
  /// at a fake host instead. Never assigned outside tests.
  @visibleForTesting
  static String? testUrl;
  @visibleForTesting
  static String? testAnonKey;

  static String get url => testUrl ?? _envUrl;
  static String get anonKey => testAnonKey ?? _envAnonKey;

  /// The running app version. Bump on each patch/release — this drives the
  /// analytics `app_version` AND the force-update comparison, so keep it in sync
  /// with SettingsScreen._version.
  ///
  /// On an OTA patch bump the BUILD number only (`+21`), never the semantic
  /// part: pubspec must stay pinned to the Shorebird release the patch attaches
  /// to (`0.9.48+20`). This constant ships inside the patch, so a patched device
  /// reports `+21` and an un-patched one still reports `+20` — that difference
  /// is how the dashboard sees the rollout.
  static const String buildVersion = '1.0.0+34';

  static bool get configured => url.isNotEmpty && anonKey.isNotEmpty;
}
