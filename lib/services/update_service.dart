import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Thin wrapper over the Shorebird updater so the UI can check for and apply an
/// over-the-air update. No-ops safely off-device (web preview / debug).
class UpdateService {
  UpdateService() : _updater = kIsWeb ? null : ShorebirdUpdater();
  final ShorebirdUpdater? _updater;

  /// True if a newer patch is available on the stable track.
  Future<bool> isUpdateAvailable() async {
    final u = _updater;
    if (u == null) return false;
    try {
      final status = await u.checkForUpdate();
      return status == UpdateStatus.outdated;
    } catch (_) {
      return false;
    }
  }

  /// Download and stage the update. Applies on the next app launch, so the UI
  /// should prompt a restart afterwards. Returns true on success.
  Future<bool> downloadUpdate() async {
    final u = _updater;
    if (u == null) return false;
    try {
      await u.update();
      return true;
    } catch (_) {
      return false;
    }
  }
}
