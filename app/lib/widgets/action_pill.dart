import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'press.dart';

/// Bottom offset that lines a screen-level action up with the shell's AI Agent
/// button.
///
/// IMPORTANT: read the **window** inset, not `MediaQuery.of(context)`. A
/// Scaffold with `extendBody: true` inflates its body's `padding.bottom` by the
/// bottom-nav height, so a page using the inherited value sits ~100px too high.
/// The AI button lives above that Scaffold and gets the true inset — this makes
/// both agree.
double agentLevelBottom(BuildContext context) =>
    MediaQueryData.fromView(View.of(context)).padding.bottom + 96;

/// A floating charcoal action button, sized (h56) and positioned to sit on the
/// same baseline as the shell's AI Agent button.
///
/// Replaces the frosted-white `GlassPill`. A screen-level action is a subject,
/// so it takes the charcoal solid and the same hard extruded face as every
/// other block — no gradient, no white-on-white glow.
class ActionPill extends StatelessWidget {
  const ActionPill({
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
    return PressFace(
      onTap: onTap,
      enabled: !busy,
      height: 56,
      rest: AppTheme.buttonFace,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: (face) => AppTheme.card(fill: AppTheme.black, offset: face),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppTheme.onAccent))
          else
            Icon(icon, size: 20, color: AppTheme.onAccent),
          const SizedBox(width: 10),
          Text(label,
              style: AppTheme.body(15,
                  weight: FontWeight.w700, color: AppTheme.onAccent)),
        ],
      ),
    );
  }
}
