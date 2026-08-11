import 'package:flutter/material.dart';

import '../services/app_restart.dart';
import '../services/remote_config.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/push_button.dart';

/// Blocking "please update" gate shown when this build is older than the
/// force-update minimum set in the admin dashboard (app_config.force_update).
/// The agent can't get past it until the app updates — used only for a genuinely
/// breaking change (e.g. a portal/DOM shift that would misbehave on old builds).
class ForceUpdateScreen extends StatefulWidget {
  const ForceUpdateScreen({super.key});

  @override
  State<ForceUpdateScreen> createState() => _ForceUpdateScreenState();
}

class _ForceUpdateScreenState extends State<ForceUpdateScreen> {
  final _updater = UpdateService();
  bool _busy = false;
  bool _ready = false; // a patch is downloaded and ready to apply on restart
  String? _note;

  @override
  void initState() {
    super.initState();
    // A patch may already be staged from a background download — if so, go
    // straight to the one-tap restart.
    _updater.isPatchStaged().then((s) {
      if (mounted && s) setState(() => _ready = true);
    });
  }

  Future<void> _update() async {
    if (_ready) {
      // Full restart (new task + process kill) so the cold start applies the
      // patch — no manual reopen.
      AppRestart.restart();
      return;
    }
    setState(() {
      _busy = true;
      _note = null;
    });
    final ok = await _updater.downloadUpdate();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ready = ok;
      _note = ok
          ? 'Update downloaded — tap "Restart & finish".'
          : 'No update found yet. Reopen the app to try again, or update from '
              'the Play Store.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final fu = RemoteConfig.forceUpdate;
    final msg = fu.message.trim().isEmpty
        ? 'A newer version of DOP Collect is required to keep working with the '
            'post-office portal. Please update to continue.'
        : fu.message.trim();
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update_rounded,
                    size: 64, color: AppTheme.black),
                const SizedBox(height: 20),
                Text('Update required',
                    style: AppTheme.display(22, weight: FontWeight.w800)),
                const SizedBox(height: 12),
                Text(msg,
                    textAlign: TextAlign.center,
                    style: AppTheme.body(14,
                        color: AppTheme.inkMuted, height: 1.45)),
                const SizedBox(height: 28),
                PushButton(
                  onPressed: _busy ? null : _update,
                  color: AppTheme.black,
                  foreground: Colors.white,
                  radius: 14,
                  expand: false,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_busy)
                        const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                      else
                        Icon(
                            _ready
                                ? Icons.restart_alt_rounded
                                : Icons.download_rounded,
                            size: 20,
                            color: Colors.white),
                      const SizedBox(width: 8),
                      Text(_busy
                          ? 'Checking…'
                          : _ready
                              ? 'Restart & finish'
                              : 'Update now'),
                    ],
                  ),
                ),
                if (_note != null) ...[
                  const SizedBox(height: 16),
                  Text(_note!,
                      textAlign: TextAlign.center,
                      style: AppTheme.body(12.5, color: AppTheme.inkMuted)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
