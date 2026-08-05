import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The vibrant yellow hero card — the single most important number on the
/// dashboard (total due), styled like the balance card in the reference.
class FocalCard extends StatelessWidget {
  const FocalCard({
    super.key,
    required this.label,
    required this.amount,
    required this.sublabel,
    this.hidden = false,
    this.onToggleVisibility,
  });
  final String label;
  final String amount;
  final String sublabel;

  /// Privacy: when true the amount is masked; the eye toggles it.
  final bool hidden;
  final VoidCallback? onToggleVisibility;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          // 3D solid edge underneath (darker yellow) + soft ambient glow.
          BoxShadow(
              color: Color(0xFFCBD348), blurRadius: 0, offset: Offset(0, 7)),
          BoxShadow(
              color: Color(0x3AB9C24A), blurRadius: 30, offset: Offset(0, 16)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 26),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF0F67A), Color(0xFFE1EA4C)],
                ),
              ),
              child: Column(
                children: [
                  Text(label.toUpperCase(),
                      style: AppTheme.label(
                          AppTheme.black.withValues(alpha: 0.75))),
                  const SizedBox(height: 10),
                  FittedBox(
                    child: Text(hidden ? '• • • • •' : amount,
                        style: AppTheme.display(58,
                            weight: FontWeight.w800, spacing: -2)),
                  ),
                  const SizedBox(height: 6),
                  Text(hidden ? 'Tap the eye to view' : sublabel,
                      style: AppTheme.body(14,
                          weight: FontWeight.w700,
                          color: AppTheme.black.withValues(alpha: 0.85))),
                ],
              ),
            ),
            // Eye toggle — hide/show the balance for privacy.
            if (onToggleVisibility != null)
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Colors.transparent,
                  child: IconButton(
                    icon: Icon(
                        hidden
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: AppTheme.black.withValues(alpha: 0.7),
                        size: 22),
                    onPressed: onToggleVisibility,
                    tooltip: hidden ? 'Show' : 'Hide',
                  ),
                ),
              ),
            // Glossy shine sweeping across the top-left.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.center,
                      colors: [
                        Colors.white.withValues(alpha: 0.45),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A clean white floating summary card: a status dot + title, the count and
/// amount, and a black round "View" button.
class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.title,
    required this.statusColor,
    required this.count,
    this.amount,
    this.onView,
    this.trailing,
  });

  final String title;
  final Color statusColor;
  final String count;
  final String? amount;
  final VoidCallback? onView;

  /// Optional compact control shown before the View button (e.g. a dropdown).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      decoration: AppTheme.card(radius: 22),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: statusColor.withValues(alpha: 0.25),
                              width: 3)),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.body(13.5,
                              weight: FontWeight.w700,
                              color: AppTheme.inkMuted)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(count,
                        style: AppTheme.display(26, weight: FontWeight.w800)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('accounts',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                AppTheme.body(13, color: AppTheme.inkFaint)),
                      ),
                    ),
                  ],
                ),
                if (amount != null) ...[
                  const SizedBox(height: 4),
                  Text(amount!,
                      style: AppTheme.display(22,
                          weight: FontWeight.w800, spacing: -0.5)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[trailing!, const SizedBox(width: 10)],
          if (onView != null)
            Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                  color: AppTheme.black, shape: BoxShape.circle),
              child: const Icon(Icons.arrow_outward_rounded,
                  color: Colors.white, size: 20),
            ),
        ],
      ),
    );
    if (onView == null) return card;
    // Whole card is tappable, not just the arrow. The trailing dropdown (if any)
    // still gets its own taps — a child gesture wins over this outer one.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onView,
      child: card,
    );
  }
}

/// Section heading between dashboard groups.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key, this.subtitle});
  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(text, style: AppTheme.display(18, weight: FontWeight.w700)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Text(subtitle!, style: AppTheme.body(12, color: AppTheme.inkMuted)),
          ],
        ],
      ),
    );
  }
}
