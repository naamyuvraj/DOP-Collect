import 'package:shared_preferences/shared_preferences.dart';

/// Small key-value settings kept on the device (agent's ASLAAS number, etc.).
class AppSettings {
  static const _kAslaas = 'aslaas_number';
  static const _kAgentName = 'agent_name';

  static Future<String> aslaas() async =>
      (await SharedPreferences.getInstance()).getString(_kAslaas) ?? '';

  static Future<void> setAslaas(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kAslaas, v.trim());

  static Future<String> agentName() async =>
      (await SharedPreferences.getInstance()).getString(_kAgentName) ?? '';

  static Future<void> setAgentName(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kAgentName, v.trim());

  static const _kDisplayName = 'display_name';
  static Future<String> displayName() async =>
      (await SharedPreferences.getInstance()).getString(_kDisplayName) ?? '';
  static Future<void> setDisplayName(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kDisplayName, v.trim());

  static const _kOnboarded = 'onboarded';
  static Future<bool> onboarded() async =>
      (await SharedPreferences.getInstance()).getBool(_kOnboarded) ?? false;
  static Future<void> setOnboarded(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kOnboarded, v);

  /// Agent's profile photo as a base64 JPEG (set via image picker). Empty = none.
  static const _kPhoto = 'profile_photo';
  static Future<String> profilePhoto() async =>
      (await SharedPreferences.getInstance()).getString(_kPhoto) ?? '';
  static Future<void> setProfilePhoto(String b64) async =>
      (await SharedPreferences.getInstance()).setString(_kPhoto, b64);

  /// Whether the guided product tour has been shown. Replayable from Settings.
  static const _kTourSeen = 'tour_seen';
  static Future<bool> tourSeen() async =>
      (await SharedPreferences.getInstance()).getBool(_kTourSeen) ?? false;
  static Future<void> setTourSeen(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kTourSeen, v);

  /// Privacy mode: when true, the AI assistant never calls the cloud — only the
  /// offline intent engine runs, so nothing (not even the schema) leaves the
  /// phone.
  static const _kOfflineOnly = 'ai_offline_only';
  static Future<bool> offlineOnlyAi() async =>
      (await SharedPreferences.getInstance()).getBool(_kOfflineOnly) ?? false;
  static Future<void> setOfflineOnlyAi(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kOfflineOnly, v);

  /// Anonymous usage analytics (default on). Opt-out from Settings.
  static const _kAnalytics = 'analytics_enabled';
  static Future<bool> analyticsEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kAnalytics) ?? true;
  static Future<void> setAnalyticsEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kAnalytics, v);

  /// User-edited RD rate history as JSON (empty = use the built-in table).
  static const _kRdRates = 'rd_rate_history_v1';
  static Future<String> rdRatesJson() async =>
      (await SharedPreferences.getInstance()).getString(_kRdRates) ?? '';
  static Future<void> setRdRatesJson(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kRdRates, v);
}
