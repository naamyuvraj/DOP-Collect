import '../services/supabase_config.dart';

/// Central config for the in-app AI assistant.
///
/// SECURITY: Groq keys now live server-side in the Supabase `groq` edge function
/// (managed from the admin dashboard's `app_keys` table). The app ships with no
/// keys — the local placeholders below are only a dev/compile fallback. See
/// supabase/functions/groq.
class AssistantConfig {
  /// 4 Groq free-tier API keys. Rotated by [GroqClient] on rate-limit / auth /
  /// server errors so one dead or throttled key never blocks an answer.
  static const List<String> groqKeys = <String>[
    String.fromEnvironment('GROQ_KEY_1', defaultValue: 'gsk_REPLACE_1'),
    String.fromEnvironment('GROQ_KEY_2', defaultValue: 'gsk_REPLACE_2'),
    String.fromEnvironment('GROQ_KEY_3', defaultValue: 'gsk_REPLACE_3'),
    String.fromEnvironment('GROQ_KEY_4', defaultValue: 'gsk_REPLACE_4'),
  ];

  static const String groqEndpoint =
      'https://api.groq.com/openai/v1/chat/completions';

  /// Tried in order per key round: strongest text-to-SQL model first, a fast
  /// cheap one as fallback.
  ///
  /// This is only a PREFERENCE. The `groq` edge function keeps the real
  /// allow-list in `app_config.groq_models` (edited on the dashboard's API Keys
  /// page) and drops anything not on it, so a retired id here degrades to the
  /// configured default rather than failing — which is why a model change needs
  /// no app update. Kept current so the preference still means something.
  ///
  /// Both are reasoning models: they spend part of the token budget thinking, so
  /// do not lower maxTokens below ~256 or the reply comes back empty.
  static const List<String> groqModels = <String>[
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
  ];

  static const Duration requestTimeout = Duration(seconds: 20);

  /// Master switch. When false, only the offline intent engine runs (no cloud).
  /// Set at startup from [RemoteConfig.assistantCloud] so it can be flipped from
  /// the admin dashboard without an app update.
  static bool cloudEnabled = true;

  /// Set to true once a cloud call has failed for a NETWORK reason (no signal,
  /// DNS, timeout) rather than a bad answer. While it is set, the assistant
  /// stops paying the timeout on every question and answers from the on-device
  /// engine instead.
  ///
  /// This replaces the old manual "Offline-only AI" switch. An agent walking a
  /// round with no bars should not have to know a setting exists — the app
  /// notices and adapts, then recovers on its own via [markNetworkOk] as soon as
  /// any call succeeds.
  static bool networkDown = false;

  static void markNetworkDown() => networkDown = true;
  static void markNetworkOk() => networkDown = false;

  /// The effective gate the service checks: cloud is on, keys exist, and the
  /// network has not just failed us.
  static bool get cloudActive => cloudEnabled && hasCloudKeys && !networkDown;

  /// Max rows returned to the UI / injected as LIMIT into generated SQL.
  static const int maxRows = 200;

  /// Cloud is reachable if the Supabase proxy is configured (keys live there)
  /// OR local Groq keys are present (dev / fallback). With the proxy the app
  /// ships with no Groq keys at all.
  static bool get hasCloudKeys =>
      SupabaseConfig.configured ||
      groqKeys.any((k) => k.isNotEmpty && !k.startsWith('gsk_REPLACE'));
}
