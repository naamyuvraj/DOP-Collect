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

  /// Every DOP agent id is `DOP.` + the agent's own code — it is the corporate
  /// id half of Finacle's `corpId.cxpsUserId`, and it is the same four
  /// characters for every agent on this portal. So the app fills it in rather
  /// than making him type it, and normalises whatever comes back.
  static const dopPrefix = 'DOP.';

  /// Force exactly one `DOP.` on the front.
  ///
  /// Handles the three ways a field with a prefilled `DOP.` goes wrong: he
  /// pastes the whole id on top of it (`DOP.DOP.MI…`), he types the bare code
  /// (`MI…`), or he types it in lower case. Empty stays empty — a blank id must
  /// stay blank, or `hasAny` starts reporting credentials that do not exist and
  /// the autofill posts a login with no password.
  static String normaliseAgentId(String raw) {
    var id = raw.trim();
    if (id.isEmpty) return '';
    while (id.toUpperCase().startsWith(dopPrefix)) {
      id = id.substring(dopPrefix.length).trimLeft();
    }
    return id.isEmpty ? '' : '$dopPrefix$id';
  }

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
    // The prefs read is INSIDE the guard. It used to sit above the try, which
    // left one narrow path — a failed `SharedPreferences.getInstance()` — that
    // could still throw out of a method whose whole contract is that it never
    // does. SyncScreen now chains the captcha solve behind this future (C3), so
    // a throw here would take the captcha down with the autofill instead of
    // just the autofill. Cheap to close, expensive to leave open.
    var remember = true;
    try {
      final p = await SharedPreferences.getInstance();
      remember = p.getBool(_kRemember) ?? true;
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
    // Normalised here too: this one is fed by `_adoptPortalAgentId`, which
    // reads `corpId.cxpsUserId` off the portal and so already carries the
    // prefix — but a portal that ever reported the bare code would otherwise
    // quietly replace a good stored id with one the login box will not take.
    final id = normaliseAgentId(agentId);
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
