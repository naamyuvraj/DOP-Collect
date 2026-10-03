import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'remote_config.dart';

/// The Android FLAG_SECURE block on screenshots, screen recording, casting and
/// the recents thumbnail.
///
/// MainActivity turns it ON at onCreate, so the app is protected from its first
/// frame — before any Dart has run, and before RemoteConfig has been read.
/// Everything here can only relax it, so the app can never start unprotected
/// and get locked down a moment later.
///
/// NOTE the fleet default is PERMISSIVE: `allow_screenshots` defaults to true,
/// so a phone that has never reached the config unblocks itself once Dart runs.
/// That is deliberate — an agent who needs to send a screenshot of a problem
/// should not have to wait on a config fetch — but it means the block is only
/// as good as the dashboard flag. The portal WebViews do not rely on it; they
/// call [forceOn] regardless.
class ScreenSecurity {
  ScreenSecurity._();
  static const _ch = MethodChannel('dop_collect/app');

  /// Apply the fleet-wide setting. Called at startup, after RemoteConfig.
  ///
  /// There is no per-device override. Whether customer data may be captured is
  /// a decision about other people's information, so it sits with the admin who
  /// is accountable for it rather than with whoever is holding the phone.
  static Future<void> applySaved() =>
      _set(!RemoteConfig.allowScreenshots);

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
