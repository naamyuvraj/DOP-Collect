import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What phone this is.
///
/// Two things come from here: the id that identifies an install to the server,
/// and the model, so the dashboard can say "Redmi Note 12" instead of a uuid.
///
/// The id used to be a random uuid in app storage, which meant an
/// uninstall/reinstall, a "Clear data", or sideloading a build signed with a
/// different key made the same phone arrive as a brand new device — taking
/// another session slot and leaving a permanent ghost row in the dashboard.
/// It is now derived from ANDROID_ID, which survives all three.
class DeviceIdentity {
  DeviceIdentity._();

  static const _channel = MethodChannel('dop_collect/app');
  static const _kId = 'analytics_device_id';

  static String? _cachedId;
  static Map<String, Object?>? _cachedInfo;

  /// Raw platform values: androidId, model, manufacturer, sdkInt.
  static Future<Map<String, Object?>> info() async {
    if (_cachedInfo != null) return _cachedInfo!;
    if (kIsWeb) return _cachedInfo = const {};
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('deviceInfo');
      return _cachedInfo = r ?? const {};
    } catch (_) {
      // Older build without the channel method, or a platform without it.
      return _cachedInfo = const {};
    }
  }

  /// "Redmi Note 12" — manufacturer and model, de-duplicated.
  ///
  /// Android reports these inconsistently: some phones already carry the brand
  /// in MODEL ("Redmi Note 12"), others don't ("SM-G991B" from "samsung"). Only
  /// prefix when it isn't already there, so nothing reads "samsung SM-G991B" on
  /// one row and "Xiaomi Redmi Note 12" on the next.
  static Future<String?> modelName() async {
    final i = await info();
    final model = (i['model'] as String?)?.trim() ?? '';
    final make = (i['manufacturer'] as String?)?.trim() ?? '';
    if (model.isEmpty) return make.isEmpty ? null : _titled(make);
    if (make.isEmpty || model.toLowerCase().startsWith(make.toLowerCase())) {
      return model;
    }
    return '${_titled(make)} $model';
  }

  static String _titled(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// The stable id for this install.
  ///
  /// Order matters, and the first rule is the important one:
  ///
  /// 1. **An id already in storage wins.** Every existing install has a random
  ///    uuid, and switching them to a derived one would spawn a second device
  ///    row for every agent at once — the exact ghosting this change exists to
  ///    stop. They keep what they have; they only pick up the durable id if
  ///    their storage is ever wiped, which is when it starts helping.
  /// 2. Otherwise derive it from ANDROID_ID, so a reinstall lands on the same
  ///    id it had before.
  /// 3. Otherwise fall back to random, so a phone that reports nothing (or the
  ///    web preview) still works exactly as it always did.
  static Future<String> id() async {
    if (_cachedId != null) return _cachedId!;
    final p = await SharedPreferences.getInstance();
    final existing = p.getString(_kId);
    if (existing != null && existing.isNotEmpty) return _cachedId = existing;

    final androidId = ((await info())['androidId'] as String?)?.trim() ?? '';
    final fresh = androidId.isEmpty || androidId == '9774d56d682e549c'
        // That literal is a well-known broken ANDROID_ID shipped by a batch of
        // old devices — thousands of phones report it, so it identifies nothing.
        ? _randomUuid()
        : _derive(androidId);

    await p.setString(_kId, fresh);
    return _cachedId = fresh;
  }

  /// A uuid-shaped value derived from ANDROID_ID.
  ///
  /// Hashed, never stored or sent raw: ANDROID_ID is a real device identifier,
  /// and the privacy screen promises an identifier for the install rather than
  /// one that follows the hardware around. Shaped like a uuid so it is
  /// indistinguishable from the ids already in the table.
  static String _derive(String androidId) {
    final d = crypto.sha256.convert(utf8.encode('dop-collect-v1:$androidId'));
    final h = d.toString().substring(0, 32);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}'
        '-a${h.substring(17, 20)}-${h.substring(20, 32)}';
  }

  static String _randomUuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
        '-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// Test seam: act out a fresh launch.
  @visibleForTesting
  static void debugReset() {
    _cachedId = null;
    _cachedInfo = null;
  }

  /// Test seam: stand in for the platform channel.
  @visibleForTesting
  static set debugInfo(Map<String, Object?>? v) => _cachedInfo = v;
}
