import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Runs [action] while showing a blocking spinner overlay, then dismisses it.
/// Use for actions that do real work (logout, sign-in, saving) so the app never
/// looks frozen. The barrier can't be dismissed by tapping away.
Future<T> runWithLoader<T>(
  BuildContext context,
  Future<T> Function() action, {
  String message = 'Please wait…',
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => PopScope(
      canPop: false,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppTheme.black),
              const SizedBox(height: 16),
              Text(message, style: AppTheme.body(13, color: AppTheme.inkMuted)),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    return await action();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}
