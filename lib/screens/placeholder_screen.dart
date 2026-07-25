import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Stub for tabs (Passbook / List / Report) not yet built.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text('$title — coming soon',
                style: const TextStyle(color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }
}
