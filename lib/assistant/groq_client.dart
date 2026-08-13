import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/session.dart';
import '../services/analytics.dart';
import '../services/supabase_config.dart';
import 'assistant_config.dart';

/// Thrown only after every (model, key) combination has failed.
class GroqUnavailable implements Exception {
  GroqUnavailable(this.detail);
  final String detail;
  @override
  String toString() => 'GroqUnavailable: $detail';
}

/// Minimal Groq chat client (OpenAI-compatible). Rotates across the 4 free-tier
/// keys and falls back across models. Uses JSON mode + temperature 0 for
/// deterministic text-to-SQL output.
class GroqClient {
  GroqClient({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;

  /// Sticky pointer to the last key that worked, so we don't keep hitting a
  /// known-throttled key first on the next question.
  int _keyStart = 0;

  /// Call the Supabase `groq` edge function (keys live server-side). Returns the
  /// content, or null to signal "proxy not available — try local keys". A hard
  /// "no keys configured" (503) surfaces as [GroqUnavailable] so the assistant
  /// doesn't silently fall back to (absent) local keys.
  Future<String?> _viaProxy({
    required String system,
    required String user,
    required bool jsonMode,
    required double temperature,
    required int maxTokens,
  }) async {
    if (!SupabaseConfig.configured) return null;
    try {
      final deviceId = await Analytics.deviceId();
      // Carries this device's verified session so the proxy can check the
      // subscription server-side (the client paywall fails open by design). No
      // session just means it can't identify us, and it serves the call anyway.
      final session = await SessionStore.load();
      final resp = await _http
          .post(
            Uri.parse('${SupabaseConfig.url}/functions/v1/groq'),
            headers: {
              'apikey': SupabaseConfig.anonKey,
              'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
              'Content-Type': 'application/json',
              'x-device-id': deviceId,
            },
            body: jsonEncode({
              'system': system,
              'user': user,
              'jsonMode': jsonMode,
              'temperature': temperature,
              'maxTokens': maxTokens,
              'models': AssistantConfig.groqModels,
              if (session != null) 'token': session.token,
            }),
          )
          .timeout(AssistantConfig.requestTimeout);
      if (resp.statusCode == 200) {
        final body =
            jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final content = body['content'];
        if (content is String && content.isNotEmpty) return content;
      }
      // Any non-200 (not deployed / no keys / error) -> fall back to local keys
      // so the assistant never breaks during the cutover.
    } catch (_) {
      // Network / not-deployed -> fall back to any local keys.
    }
    return null;
  }

  /// Returns the assistant message content (expected to be a JSON string).
  /// Throws [GroqUnavailable] only when all keys and models are exhausted.
  Future<String> completeJson({
    required String system,
    required String user,
  }) =>
      _complete(system: system, user: user, jsonMode: true);

  /// Free-text completion (no JSON mode) for general DOP knowledge questions.
  Future<String> completeText({
    required String system,
    required String user,
    double temperature = 0.3,
  }) =>
      _complete(
          system: system,
          user: user,
          jsonMode: false,
          temperature: temperature,
          maxTokens: 700);

  Future<String> _complete({
    required String system,
    required String user,
    required bool jsonMode,
    double temperature = 0,
    int maxTokens = 512,
  }) async {
    // PRIMARY: the Supabase proxy holds the keys server-side, so the app ships
    // with none. Falls through to any local keys only if the proxy is
    // unavailable (dev / migration), so the assistant never breaks mid-cutover.
    final proxied = await _viaProxy(
      system: system,
      user: user,
      jsonMode: jsonMode,
      temperature: temperature,
      maxTokens: maxTokens,
    );
    if (proxied != null) return proxied;

    const keys = AssistantConfig.groqKeys;
    const models = AssistantConfig.groqModels;
    final errors = <String>[];

    for (final model in models) {
      for (var i = 0; i < keys.length; i++) {
        final keyIdx = (_keyStart + i) % keys.length;
        final key = keys[keyIdx];
        if (key.isEmpty || key.startsWith('gsk_REPLACE')) {
          errors.add('key#$keyIdx not configured');
          continue;
        }
        try {
          final resp = await _http
              .post(
                Uri.parse(AssistantConfig.groqEndpoint),
                headers: {
                  'Authorization': 'Bearer $key',
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({
                  'model': model,
                  'temperature': temperature,
                  'max_tokens': maxTokens,
                  if (jsonMode) 'response_format': {'type': 'json_object'},
                  'messages': [
                    {'role': 'system', 'content': system},
                    {'role': 'user', 'content': user},
                  ],
                }),
              )
              .timeout(AssistantConfig.requestTimeout);

          if (resp.statusCode == 200) {
            _keyStart = keyIdx; // stick to this working key next time
            unawaited(Analytics.keyUsage(keyIdx, model, true));
            final body =
                jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
            final content = ((body['choices'] as List).first
                as Map<String, dynamic>)['message']['content'] as String;
            return content;
          }

          // Rotate on rate-limit / auth / server errors — another key may work.
          if (resp.statusCode == 429 ||
              resp.statusCode == 401 ||
              resp.statusCode == 403 ||
              resp.statusCode >= 500) {
            unawaited(Analytics.keyUsage(keyIdx, model, false));
            errors.add('key#$keyIdx/$model -> HTTP ${resp.statusCode}');
            continue; // next key
          }

          // 400/422 etc. = request problem; rotating keys won't help -> next model.
          final snippet =
              resp.body.substring(0, resp.body.length.clamp(0, 160));
          errors.add('key#$keyIdx/$model -> HTTP ${resp.statusCode}: $snippet');
          break; // break key loop, try next model
        } on TimeoutException {
          errors.add('key#$keyIdx/$model -> timeout');
          continue;
        } catch (e) {
          errors.add('key#$keyIdx/$model -> $e');
          continue;
        }
      }
    }
    throw GroqUnavailable(errors.join(' | '));
  }

  void dispose() => _http.close();
}
