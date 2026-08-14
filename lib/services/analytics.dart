import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/agent_id.dart';
import '../data/app_settings.dart';
import '../data/credentials.dart';
import '../data/session.dart';
import 'device_identity.dart';
import 'supabase_config.dart';

/// Product + account telemetry -> Supabase (via the `ingest` edge function).
/// Fire-and-forget: every call swallows errors and no-ops when Supabase isn't
/// configured or the user has opted out.
///
/// NOT anonymous, and the privacy screen says so — [identify] deliberately
/// sends the agent's own identity (display name, mobile, agent name, DOP agent
/// id and SOL branch code) so the dashboard can support a named agent and roll
/// usage up per region. Keep `PrivacyScreen`'s "What we do collect" section in
/// step with this method: if a field is added here, it is disclosed there.
///
/// What is NEVER sent, and must stay that way: customer names, account numbers,
/// amounts, due dates, the agent's portal PASSWORD, or the questions typed into
/// the assistant. Event props are limited to counts and scheme codes.
///
/// The opt-out covers everything in this class — including [identify].
class Analytics {
  static bool _identified = false;
  static bool _enabled = true;

  /// Set the fleet-wide switch once at startup.
  ///
  /// The per-device opt-out toggle is gone; analytics is on by default and is
  /// disclosed in the Privacy Policy the agent accepts before signing up. What
  /// remains is [defaultEnabled], driven by `RemoteConfig.analyticsDefault`, so
  /// collection can still be halted for everyone from the dashboard without
  /// shipping an app update.
  static Future<void> init({bool defaultEnabled = true}) async {
    _enabled = defaultEnabled;
  }

  static void setEnabled(bool v) => _enabled = v;

  /// This phone's id — see [DeviceIdentity.id] for how it is chosen and what it
  /// survives. Resolved regardless of the analytics opt-out, because the OTP
  /// session and the Groq rate limit both key on it.
  static Future<String> deviceId() => DeviceIdentity.id();

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
    final mobile = await AppSettings.mobile();
    // Attach the DOP agent id + its SOL ID (post-office branch) so the dashboard
    // can track usage per agent and per region. Empty until the agent has logged
    // in (identify is re-sent with force:true right after login).
    final agentId = (await Credentials.load()).agentId.trim();
    final sol = AgentId.solOf(agentId);
    // The handset itself — so a support call can start from "which phone is
    // this" rather than a uuid, and so a build that misbehaves on one model is
    // visible as a pattern.
    final model = await DeviceIdentity.modelName();
    await _ingest('device', {
      'id': await _did(),
      // `name` is deliberately no longer sent — there is one name now, and it
      // travels as `agent_name`. `ingest` still ACCEPTS `name` so phones on an
      // older build keep populating their row until they update.
      'mobile': mobile.isEmpty ? null : mobile,
      'agent_name': name.isEmpty ? null : name,
      'agent_id': agentId.isEmpty ? null : agentId,
      'sol_id': sol.isEmpty ? null : sol,
      'model': (model == null || model.isEmpty) ? null : model,
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
  /// (the anon key can no longer INSERT directly), carrying this device's
  /// session token when it has one. Fire-and-forget.
  ///
  /// The token is what proves the `devices` row being written is ours. Once an
  /// install verifies its phone, the server stamps the row with an account and
  /// refuses writes that can't prove they belong to it — otherwise anyone
  /// holding the anon key could rewrite a real agent's name, mobile and agent
  /// id, which is exactly what the admin panel reads. Before verification there
  /// is no token and no claim to protect, so first-run telemetry is unaffected.
  static Future<void> _ingest(String kind, Map<String, Object?> row) async {
    try {
      final session = await SessionStore.load();
      await http
          .post(
            Uri.parse('${SupabaseConfig.url}/functions/v1/ingest'),
            headers: {
              'apikey': SupabaseConfig.anonKey,
              'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
              'Content-Type': 'application/json',
              'x-device-id': await _did(),
            },
            body: jsonEncode({
              'kind': kind,
              'row': row,
              if (session != null) 'token': session.token,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Telemetry must never affect the app; drop silently.
    }
  }

  static Future<String> _did() => DeviceIdentity.id();
}
