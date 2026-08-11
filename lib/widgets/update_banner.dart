import 'package:flutter/material.dart';

import '../services/app_restart.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';

/// Home card shown once an OTA update has been DOWNLOADED and is ready to apply.
///
/// Updates download silently in the background (see main.dart + UpdateService),
/// so this stays hidden until there's actually a staged patch. Tapping Restart
/// fully closes the app — the only thing that makes the next launch pick up the
/// new patch. (The old flow used SystemNavigator.pop(), which just backgrounds
/// the app, so the update needed two open/close cycles to appear.)
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  final _service = UpdateService();
  bool _staged = false;

  @override
  void initState() {
    super.initState();
    // Trigger/observe the background download. If startup already began one,
    // UpdateService dedupes to the same in-flight download.
    _service.downloadUpdate().then((staged) {
      if (mounted && staged) setState(() => _staged = true);
    });
  }

  Future<void> _restart() async {
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Update ready', style: AppTheme.display(18)),
        content: Text(
          'The app will restart to finish updating. It only takes a moment.',
          style: AppTheme.body(13, color: AppTheme.inkMuted, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.black),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restart now'),
          ),
        ],
      ),
    );
    if (go == true) {
      // Full restart (native): launches a fresh task AND kills the process, so
      // the next (cold) start applies the downloaded patch — no manual reopen.
      AppRestart.restart();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_staged) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: AppTheme.focal,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.rocket_launch_rounded,
              color: AppTheme.black, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Update ready',
                    style: AppTheme.body(14, weight: FontWeight.w800)),
                Text('Restart to get the latest',
                    style: AppTheme.body(12,
                        color: AppTheme.black.withValues(alpha: 0.6))),
              ],
            ),
          ),
          GestureDetector(
            onTap: _restart,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                  color: AppTheme.black,
                  borderRadius: BorderRadius.circular(12)),
              child: Text('Restart',
                  style: AppTheme.body(13,
                      weight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
