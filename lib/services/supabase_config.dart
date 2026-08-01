/// Supabase analytics configuration.
///
/// PASTE your Project URL + **anon (public)** key below (Supabase -> Settings ->
/// API). The anon key is safe to ship — RLS only lets it INSERT telemetry, never
/// read. Leave both blank to disable analytics entirely (nothing is sent).
///
/// You can also pass them at build time instead of hardcoding:
///   flutter build ... --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class SupabaseConfig {
  static const String url =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const String anonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// The running app version. Bump on each patch/release — this drives the
  /// analytics `app_version` AND the force-update comparison, so keep it in sync
  /// with SettingsScreen._version.
  static const String buildVersion = '0.9.37';

  static bool get configured => url.isNotEmpty && anonKey.isNotEmpty;
}
