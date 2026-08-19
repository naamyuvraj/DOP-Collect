import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../data/app_settings.dart';

/// The Android FLAG_SECURE block on screenshots, screen recording, casting and
/// the recents thumbnail.
///
/// MainActivity turns it ON at onCreate, so the app is protected from its first
/// frame — before any Dart has run. Everything here can only relax it, and only
/// because the agent asked in Settings. The app can never start unprotected and
/// get locked down a moment later.
class ScreenSecurity {
  ScreenSecurity._();
  static const _ch = MethodChannel('dop_collect/app');

  /// Apply the saved preference. Called once at startup.
  static Future<void> applySaved() async =>
      _set(!await AppSettings.allowScreenshots());

  /// Change the preference and apply it immediately.
  static Future<void> setAllowed(bool allowed) async {
    await AppSettings.setAllowScreenshots(allowed);
    await _set(!allowed);
  }

  /// Force the block on regardless of the setting.
  ///
  /// The portal WebView is the reason this exists: the agent types his real DOP
  /// banking password into it. That is not his to expose even if he has turned
  /// screenshots on for his own convenience, and a screen recorder left running
  /// would otherwise catch it. Pair every call with [applySaved] in `dispose`.
  static Future<void> forceOn() => _set(true);

  static Future<void> _set(bool secure) async {
    if (kIsWeb) return;
    try {
      await _ch.invokeMethod('setSecure', {'on': secure});
    } catch (_) {
      // An older build without the channel method stays as it was — which is
      // secure, because that is what MainActivity set at launch.
    }
  }
}
