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
  });
  final String label;
  final String amount;
  final String sublabel;

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
                          AppTheme.black.withValues(alpha: 0.55))),
                  const SizedBox(height: 10),
                  FittedBox(
                    child: Text(amount,
                        style: AppTheme.display(46,
                            weight: FontWeight.w800, spacing: -1.5)),
                  ),
                  const SizedBox(height: 6),
                  Text(sublabel,
                      style: AppTheme.body(14,
                          weight: FontWeight.w700,
                          color: AppTheme.black.withValues(alpha: 0.7))),
                ],
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
  });

  final String title;
  final Color statusColor;
  final String count;
  final String? amount;
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    return Container(
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
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: statusColor, shape: BoxShape.circle),
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
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text('accounts',
                          style:
                              AppTheme.body(12.5, color: AppTheme.inkFaint)),
                    ),
                  ],
                ),
                if (amount != null) ...[
                  const SizedBox(height: 2),
                  Text(amount!,
                      style: AppTheme.body(14.5,
                          weight: FontWeight.w700, color: AppTheme.ink)),
                ],
              ],
            ),
          ),
          if (onView != null)
            GestureDetector(
              onTap: onView,
              child: Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                    color: AppTheme.black, shape: BoxShape.circle),
                child: const Icon(Icons.arrow_outward_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
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
