import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/update_service.dart';
import '../theme/app_theme.dart';

/// A dismissible card that appears on Home when an OTA update is available.
/// Tapping Update downloads it and prompts a quick restart to finish.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  final _service = UpdateService();
  bool _available = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _service.isUpdateAvailable().then((v) {
      if (mounted && v) setState(() => _available = true);
    });
  }

  Future<void> _update() async {
    setState(() => _working = true);
    final ok = await _service.downloadUpdate();
    if (!mounted) return;
    setState(() => _working = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Update failed. Try again later.')));
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Update ready', style: AppTheme.display(18)),
        content: Text('Tap restart to finish updating the app.',
            style: AppTheme.body(13, color: AppTheme.inkMuted)),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.black),
            onPressed: () => SystemNavigator.pop(), // close; reopen applies patch
            child: const Text('Restart'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
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
                Text('New version available',
                    style: AppTheme.body(14, weight: FontWeight.w800)),
                Text('Update to get the latest',
                    style: AppTheme.body(12, color: AppTheme.black.withValues(alpha: 0.6))),
              ],
            ),
          ),
          GestureDetector(
            onTap: _working ? null : _update,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                  color: AppTheme.black,
                  borderRadius: BorderRadius.circular(12)),
              child: _working
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text('Update',
                      style: AppTheme.body(13,
                          weight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
