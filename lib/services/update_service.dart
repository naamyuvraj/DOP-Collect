import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Thin wrapper over the Shorebird updater.
///
/// The key fact: a Shorebird patch only becomes active on a genuine COLD START
/// (a full process restart). Merely backgrounding the app (SystemNavigator.pop)
/// keeps the same warm process running the OLD code — which is exactly why an
/// update used to need TWO open/close cycles to appear.
///
/// Strategy:
///   1. [downloadUpdate] silently downloads any available patch in the
///      background (called at startup), so it's staged with no user action;
///   2. [isPatchStaged] lets the UI show a "restart to finish" prompt once it's
///      ready — and a real restart applies it in one cycle (or it applies on the
///      next natural cold start anyway).
///
/// No-ops safely off-device (web preview / debug), where the updater is absent.
class UpdateService {
  UpdateService() : _updater = kIsWeb ? null : ShorebirdUpdater();
  final ShorebirdUpdater? _updater;

  // Dedupe concurrent downloads: startup and the Home banner both trigger a
  // check, but we only ever want one download in flight at a time.
  static Future<bool>? _inflight;

  /// True once a patch has been downloaded and will apply on the next cold
  /// start. Cheap — does not hit the network.
  Future<bool> isPatchStaged() async {
    final u = _updater;
    if (u == null) return false;
    try {
      return (await u.readNextPatch()) != null;
    } catch (_) {
      return false;
    }
  }

  /// Check for and download the latest patch. Safe to call every launch: it only
  /// downloads when the app is actually outdated. Returns true if a patch is
  /// staged and ready to apply on the next restart. Concurrent callers share the
  /// same in-flight download.
  Future<bool> downloadUpdate() {
    final existing = _inflight;
    if (existing != null) return existing;
    final f = _stage();
    _inflight = f;
    f.whenComplete(() => _inflight = null);
    return f;
  }

  Future<bool> _stage() async {
    final u = _updater;
    if (u == null) return false;
    try {
      final status = await u.checkForUpdate();
      if (status == UpdateStatus.outdated) {
        await u.update(); // downloads + stages for the next launch
      }
      return (await u.readNextPatch()) != null;
    } catch (_) {
      return false;
    }
  }
}
