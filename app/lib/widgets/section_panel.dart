import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A flat nested well that groups a section's cards.
///
/// Replaces the old pastel `GlassPanel`. That one gave every section its own
/// tinted, blurred, shadowed slab — three tinted surfaces competing on a phone
/// screen that has the least room to spend on them. Here the well is one
/// neutral inset and the grouping is carried by whitespace and the heading, so
/// the only colour left on the page is the one that means something.
class SectionPanel extends StatelessWidget {
  const SectionPanel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.fromLTRB(14, 14, 14, 16),
      decoration: AppTheme.panel(AppTheme.surfaceSoft,
          radius: AppTheme.cardRadius),
      child: child,
    );
  }
}
