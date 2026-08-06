import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/agent_id.dart';
import '../data/app_settings.dart';
import '../data/credentials.dart';
import 'supabase_config.dart';

/// Anonymous, privacy-safe product analytics -> Supabase (via the REST API with
/// the anon key). Fire-and-forget: every call swallows errors and no-ops when
/// Supabase isn't configured or the user has opted out.
///
/// What is sent: a random per-install device id, event names, and small numeric
/// props (counts / amounts / scheme codes). What is NEVER sent: customer names,
/// account numbers, the agent's login, or the questions typed into the
/// assistant.
class Analytics {
  static String? _deviceId;
  static bool _identified = false;
  static bool _enabled = true; // mirrors the user's opt-out, loaded at startup

  /// Load the opt-out flag once at startup. [defaultEnabled] is the value used
  /// for a brand-new install that hasn't chosen yet (from remote config).
  static Future<void> init({bool defaultEnabled = true}) async {
    _enabled = await AppSettings.analyticsEnabled(orDefault: defaultEnabled);
  }

  static void setEnabled(bool v) => _enabled = v;

  /// Stable anonymous per-install id — also used by the Groq proxy for
  /// per-device rate limiting. Generated regardless of the analytics opt-out.
  static Future<String> deviceId() => _did();

  static bool get _live => SupabaseConfig.configured && _enabled;

  // --- Public events ---------------------------------------------------------

  /// Upsert the device row (fresh last_seen). Runs once per launch; pass
  /// [force] to re-send after something changes (e.g. the agent name is set
  /// during onboarding, so the device row gets the name without waiting for the
  /// next launch).
  static Future<void> identify({bool force = false}) async {
    if (!_live || (_identified && !force)) return;
    _identified = true;
    final name = await AppSettings.agentName();
    // Attach the DOP agent id + its SOL ID (post-office branch) so the dashboard
    // can track usage per agent and per region. Empty until the agent has logged
    // in (identify is re-sent with force:true right after login).
    final agentId = (await Credentials.load()).agentId.trim();
    final sol = AgentId.solOf(agentId);
    await _ingest('device', {
      'id': await _did(),
      'agent_name': name.isEmpty ? null : name,
      'agent_id': agentId.isEmpty ? null : agentId,
      'sol_id': sol.isEmpty ? null : sol,
      'app_version': SupabaseConfig.buildVersion,
      'platform': 'android',
    });
  }

  static Future<void> track(String event, [Map<String, Object?>? props]) async {
    if (!_live) return;
    await _ingest('event', {
      'device_id': await _did(),
      'event': event,
      'props': props ?? const {},
      'app_version': SupabaseConfig.buildVersion,
    });
  }

  /// Which Groq key/model was used and whether it succeeded (key rotation view).
  static Future<void> keyUsage(int keyIndex, String model, bool ok) async {
    if (!_live) return;
    await _ingest('key_usage', {
      'device_id': await _did(),
      'key_index': keyIndex,
      'model': model,
      'ok': ok,
    });
  }

  // --- Internals -------------------------------------------------------------

  /// Post one telemetry row through the rate-limited `ingest` edge function
  /// (the anon key can no longer INSERT directly). Fire-and-forget.
  static Future<void> _ingest(String kind, Map<String, Object?> row) async {
    try {
      await http
          .post(
            Uri.parse('${SupabaseConfig.url}/functions/v1/ingest'),
            headers: {
              'apikey': SupabaseConfig.anonKey,
              'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
              'Content-Type': 'application/json',
              'x-device-id': await _did(),
            },
            body: jsonEncode({'kind': kind, 'row': row}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Telemetry must never affect the app; drop silently.
    }
  }

  static Future<String> _did() async {
    if (_deviceId != null) return _deviceId!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString('analytics_device_id');
    if (id == null || id.isEmpty) {
      id = _uuidV4();
      await p.setString('analytics_device_id', id);
    }
    return _deviceId = id;
  }

  static String _uuidV4() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
        '-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
