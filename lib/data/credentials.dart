import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/analytics.dart';

/// Stores the agent's DOP login on the device so Sync can auto-fill the Agent
/// ID and password (the captcha is always typed manually). Local-only — nothing
/// leaves the phone.
///
/// The ID and password live in the Android **Keystore** via
/// flutter_secure_storage (encrypted at rest), NOT plaintext SharedPreferences.
/// Only the non-secret "remember" flag stays in prefs. Existing installs that
/// saved plaintext creds are migrated into secure storage once, on first load.
class Credentials {
  static const _kId = 'agent_id';
  static const _kPw = 'agent_pw';
  static const _kRemember = 'agent_remember';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final String agentId;
  final String password;
  final bool remember;

  const Credentials({
    this.agentId = '',
    this.password = '',
    this.remember = true,
  });

  bool get hasAny => agentId.isNotEmpty || password.isNotEmpty;

  /// Never throws.
  ///
  /// A Keystore read can fail — the key is invalidated by a lock-screen change,
  /// the vendor's provider misbehaves after an OS update, the device is in
  /// direct-boot. SyncScreen stores this future in `_credsReady` and awaits it
  /// unawaited, so a throw here became an unhandled async error: autofill was
  /// dead for the life of the screen and nothing said why.
  ///
  /// Degrading to empty credentials is the honest failure. The agent sees the
  /// fields unfilled and types them, which is exactly what he would do if he
  /// had never saved them — instead of a screen that silently refuses to help.
  static Future<Credentials> load() async {
    final p = await SharedPreferences.getInstance();
    final remember = p.getBool(_kRemember) ?? true;
    try {
      await _migratePlaintext(p);
      return Credentials(
        agentId: await _secure.read(key: _kId) ?? '',
        password: await _secure.read(key: _kPw) ?? '',
        remember: remember,
      );
    } catch (e, st) {
      // Reported, not swallowed: a fleet-wide Keystore regression should show
      // up on the dashboard rather than as "autofill stopped working".
      Analytics.error('keystore', 'Credentials.load failed: $e',
          detail: st.toString(), screen: 'credentials');
      return Credentials(remember: remember);
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kRemember, remember);
    if (remember) {
      await _secure.write(key: _kId, value: agentId);
      await _secure.write(key: _kPw, value: password);
    } else {
      await _secure.delete(key: _kId);
      await _secure.delete(key: _kPw);
    }
  }

  /// Overwrite just the agent id, keeping the password and the remember flag.
  ///
  /// Used to adopt the id the PORTAL reports over the one that was typed. A
  /// full `save()` here would need the password in hand and would rewrite the
  /// remember flag as a side effect, neither of which this caller knows about.
  static Future<void> saveAgentId(String agentId) async {
    final id = agentId.trim();
    if (id.isEmpty) return;
    await _secure.write(key: _kId, value: id);
  }

  static Future<void> clear() async {
    await _secure.delete(key: _kId);
    await _secure.delete(key: _kPw);
  }

  /// One-time move of any pre-existing plaintext credentials from prefs into
  /// the Keystore, then wipe the plaintext copies.
  static Future<void> _migratePlaintext(SharedPreferences p) async {
    final oldId = p.getString(_kId);
    final oldPw = p.getString(_kPw);
    if ((oldId == null || oldId.isEmpty) && (oldPw == null || oldPw.isEmpty)) {
      return;
    }
    if (oldId != null && oldId.isNotEmpty) {
      await _secure.write(key: _kId, value: oldId);
    }
    if (oldPw != null && oldPw.isNotEmpty) {
      await _secure.write(key: _kPw, value: oldPw);
    }
    await p.remove(_kId);
    await p.remove(_kPw);
  }
}
