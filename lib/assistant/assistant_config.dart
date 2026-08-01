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
  /// cheap one as fallback. Update if Groq deprecates a model id.
  static const List<String> groqModels = <String>[
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
  ];

  static const Duration requestTimeout = Duration(seconds: 20);

  /// Master switch. When false, only the offline intent engine runs (no cloud).
  static const bool cloudEnabled = true;

  /// Privacy toggle set by the user (loaded at startup from AppSettings). When
  /// true, the assistant stays fully offline even if keys are present.
  static bool userOfflineOnly = false;

  /// The effective gate the service checks: cloud is on, keys exist, and the
  /// user hasn't switched to offline-only.
  static bool get cloudActive =>
      cloudEnabled && hasCloudKeys && !userOfflineOnly;

  /// Max rows returned to the UI / injected as LIMIT into generated SQL.
  static const int maxRows = 200;

  /// Cloud is reachable if the Supabase proxy is configured (keys live there)
  /// OR local Groq keys are present (dev / fallback). With the proxy the app
  /// ships with no Groq keys at all.
  static bool get hasCloudKeys =>
      SupabaseConfig.configured ||
      groqKeys.any((k) => k.isNotEmpty && !k.startsWith('gsk_REPLACE'));
}
