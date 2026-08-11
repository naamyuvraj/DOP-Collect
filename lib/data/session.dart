import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The verified device session issued by the `otp` edge function after a
/// successful WhatsApp OTP verify. Held in the Android Keystore (never plain
/// prefs) because the token is a bearer credential for this device's slot.
///
/// Enforcement is server-side: the edge function keeps only the newest
/// `max_devices` sessions per account and revokes the rest, so a token can be
/// invalidated remotely ("signed out on another device"). The app checks it with
/// [SessionStore]-backed `session_check` at startup.
class Session {
  final String token;
  final String accountId;
  final String phone; // last 10 digits, display only
  final String agentId; // the DOP agent id this session is bound to (1:1)
  const Session(this.token, this.accountId, this.phone, this.agentId);
}

class SessionStore {
  SessionStore._();

  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kToken = 'otp_session_token';
  static const _kAccount = 'otp_session_account';
  static const _kPhone = 'otp_session_phone';
  static const _kAgent = 'otp_session_agent';

  static Session? _cache;

  static Future<Session?> load() async {
    if (_cache != null) return _cache;
    try {
      final t = await _s.read(key: _kToken);
      if (t == null || t.isEmpty) return null;
      _cache = Session(
        t,
        await _s.read(key: _kAccount) ?? '',
        await _s.read(key: _kPhone) ?? '',
        await _s.read(key: _kAgent) ?? '',
      );
      return _cache;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Session s) async {
    _cache = s;
    try {
      await _s.write(key: _kToken, value: s.token);
      await _s.write(key: _kAccount, value: s.accountId);
      await _s.write(key: _kPhone, value: s.phone);
      await _s.write(key: _kAgent, value: s.agentId);
    } catch (_) {/* session just won't persist; re-verify next launch */}
  }

  static Future<void> clear() async {
    _cache = null;
    try {
      await _s.delete(key: _kToken);
      await _s.delete(key: _kAccount);
      await _s.delete(key: _kPhone);
      await _s.delete(key: _kAgent);
    } catch (_) {/* ignore */}
  }

  /// Whether a verified session exists on this device (offline check only).
  static Future<bool> get exists async => (await load()) != null;
}
