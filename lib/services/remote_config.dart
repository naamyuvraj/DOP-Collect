import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_config.dart';

/// Remote app configuration read from the Supabase `app_config` table (managed
/// from the admin dashboard) — feature flags, kill switches, an announcement
/// banner and a force-update gate, all changeable WITHOUT an app update.
///
/// Design for a budget phone on flaky data:
///  - the last-fetched config is cached to disk and loaded instantly at startup,
///  - a fresh copy is fetched in the background (never blocks the UI),
///  - every getter has a safe default, so a missing key or no network just falls
///    back to the shipped behaviour.
///
/// The `app_config` table is anon-readable by RLS (SELECT only); the app can
/// never write it. Values are jsonb: booleans come back as bool, the banner /
/// force-update come back as objects.
class RemoteConfig {
  RemoteConfig._();

  static const _cacheKey = 'remote_config_v1';
  static final Map<String, dynamic> _values = {};
  static bool _loaded = false;

  /// Load the cached config (instant) then refresh from the network. Call once
  /// at startup, before anything reads a flag.
  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final cached = p.getString(_cacheKey);
    if (cached != null) {
      try {
        _values.addAll((jsonDecode(cached) as Map).cast<String, dynamic>());
      } catch (_) {/* corrupt cache — ignore */}
    }
    _loaded = true;
    // Background refresh; failures are silent and keep the cached values.
    unawaited(refresh());
  }

  /// Re-pull the whole config. Safe to call any time (e.g. after a sync).
  static Future<void> refresh() async {
    if (!SupabaseConfig.configured) return;
    try {
      final res = await http.get(
        Uri.parse('${SupabaseConfig.url}/rest/v1/app_config?select=key,value'),
        headers: {
          'apikey': SupabaseConfig.anonKey,
          'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
        },
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode >= 300) return;
      final rows = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
      final map = {for (final r in rows) r['key'] as String: r['value']};
      _values
        ..clear()
        ..addAll(map);
      final p = await SharedPreferences.getInstance();
      await p.setString(_cacheKey, jsonEncode(_values));
    } catch (_) {
      // Offline / server error — keep whatever we had cached.
    }
  }

  static bool get loaded => _loaded;

  // --- Typed accessors -------------------------------------------------------

  static bool _flag(String key, {required bool def}) {
    final v = _values[key];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() != 'false';
    if (v is num) return v != 0;
    return def;
  }

  static Map<String, dynamic> _obj(String key) {
    final v = _values[key];
    return v is Map ? v.cast<String, dynamic>() : const {};
  }

  /// Master switch for the cloud AI tier. Off => every install is offline-only.
  static bool get assistantCloud => _flag('assistant_cloud', def: true);

  /// Default analytics opt-in for a NEW install (before the user chooses).
  static bool get analyticsDefault => _flag('analytics_default', def: true);

  /// Kill switch for the portal auto-submit / pay flow. Off => the "Submit on
  /// Portal" actions are hidden everywhere (the risky automation can't run).
  static bool get portalSubmit => _flag('portal_submit', def: true);

  /// Home-screen announcement banner.
  static ({String text, bool enabled}) get announcement {
    final m = _obj('announcement');
    return (
      text: (m['text'] ?? '').toString(),
      enabled: m['enabled'] == true,
    );
  }

  /// Blocking "please update" gate for installs below [version].
  static ({String version, String message, bool enabled}) get forceUpdate {
    final m = _obj('force_update');
    return (
      version: (m['version'] ?? '').toString(),
      message: (m['message'] ?? '').toString(),
      enabled: m['enabled'] == true,
    );
  }

  /// True when this build (SupabaseConfig.buildVersion) is OLDER than the
  /// force-update minimum. Compares the numeric `major.minor.patch(+build)`
  /// parts only; a blank/garbled minimum never blocks.
  static bool get updateRequired {
    final fu = forceUpdate;
    if (!fu.enabled || fu.version.trim().isEmpty) return false;
    return versionLess(SupabaseConfig.buildVersion, fu.version);
  }

  /// Compare "0.9.35" / "0.9.3+12" style versions. Returns true if [a] < [b].
  /// Public so the force-update gate logic can be unit-tested.
  static bool versionLess(String a, String b) {
    List<int> parts(String s) => s
        .split(RegExp(r'[.+]'))
        .map((x) => int.tryParse(x.trim()) ?? 0)
        .toList();
    final pa = parts(a), pb = parts(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }
}
