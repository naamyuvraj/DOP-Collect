import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Bottom offset that lines a screen-level action pill up with the shell's AI
/// Agent button.
///
/// IMPORTANT: read the **window** inset, not `MediaQuery.of(context)`. A
/// Scaffold with `extendBody: true` inflates its body's `padding.bottom` by the
/// bottom-nav height, so a page using the inherited value sits ~100px too high.
/// The AI button lives above that Scaffold and gets the true inset — this makes
/// both agree.
double agentLevelBottom(BuildContext context) =>
    MediaQueryData.fromView(View.of(context)).padding.bottom + 96;

/// A frosted-glass floating pill button. Sized (h56) and positioned to sit on
/// the same baseline as the shell's AI Agent button (a 58px circle at
/// `padding.bottom + 96`), so screen actions line up with it.
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.label,
    required this.icon,
    this.onTap,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: busy ? null : onTap,
            borderRadius: BorderRadius.circular(30),
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.88),
                    Colors.white.withValues(alpha: 0.55),
                  ],
                ),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.75), width: 1.2),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x2621A06A),
                      blurRadius: 26,
                      offset: Offset(0, 12)),
                  BoxShadow(
                      color: Color(0x14101B12),
                      blurRadius: 8,
                      offset: Offset(0, 4)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.ink))
                      : Icon(icon, size: 20, color: AppTheme.ink),
                  const SizedBox(width: 10),
                  Text(label,
                      style: AppTheme.body(15,
                          weight: FontWeight.w700, color: AppTheme.ink)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
