import 'package:flutter/material.dart';

/// A soft pastel panel with a light edge highlight and a 3D drop shadow. Each
/// dashboard section uses its own [tint] for a subtle coloured shine over the
/// mint canvas.
///
/// Deliberately a FLAT translucent tint, not a real-time `BackdropFilter` blur:
/// four live blurs on the scrolling dashboard janked badly on a ₹9,000 phone,
/// and over the static gradient the flat fill is visually near-identical.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.tint = const Color(0xFFA8DCBC),
    this.padding,
  });

  final Widget child;
  final Color tint;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
              color: tint.withValues(alpha: 0.32),
              blurRadius: 28,
              offset: const Offset(0, 16)),
          const BoxShadow(
              color: Color(0x12101B12), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: padding ?? const EdgeInsets.fromLTRB(14, 14, 14, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tint.withValues(alpha: 0.85),
                tint.withValues(alpha: 0.62),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: const Color(0x80FFFFFF), width: 1.2),
          ),
          child: child,
        ),
      ),
    );
  }
}
