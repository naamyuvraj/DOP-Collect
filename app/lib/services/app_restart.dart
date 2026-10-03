import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Fully restarts the app via a native MethodChannel (launch intent + process
/// kill in MainActivity). The cold relaunch is what makes the app pick up a
/// downloaded Shorebird patch — a plain SystemNavigator.pop() only backgrounds
/// the app, leaving the old code running.
class AppRestart {
  AppRestart._();
  static const _ch = MethodChannel('dop_collect/app');

  /// Restart now. No-op on web. Best-effort — never throws to the caller.
  static Future<void> restart() async {
    if (kIsWeb) return;
    try {
      await _ch.invokeMethod('restart');
    } catch (_) {/* ignore — worst case the user reopens manually */}
  }
}
