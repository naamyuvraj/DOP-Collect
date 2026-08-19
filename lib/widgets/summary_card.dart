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
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
      // One flat neon block extruded in its OWN shadow, not grey — that is
      // what stops it reading as a sticker laid on the page.
      decoration: AppTheme.card(fill: AppTheme.focal),
      child: Stack(
        children: [
          // Must be told to fill: a Stack hands its non-positioned children
          // LOOSE constraints, so an unbounded Column shrink-wraps to its
          // widest line and then centres its text on itself rather than on the
          // card — the label ends up floating off to one side.
          SizedBox(
            width: double.infinity,
            child: Column(
              children: [
                Text(label.toUpperCase(),
                    style: AppTheme.label(
                        AppTheme.onFocal.withValues(alpha: 0.75))),
                const SizedBox(height: 10),
                FittedBox(
                  child: Text(hidden ? '• • • • •' : amount,
                      style: AppTheme.display(58,
                          weight: FontWeight.w800,
                          spacing: -2,
                          color: AppTheme.onFocal)),
                ),
                const SizedBox(height: 6),
                Text(hidden ? 'Tap the eye to view' : sublabel,
                    style: AppTheme.body(14,
                        weight: FontWeight.w700,
                        color: AppTheme.onFocal.withValues(alpha: 0.85))),
              ],
            ),
          ),
          // Eye toggle — hide/show the balance for privacy.
          if (onToggleVisibility != null)
            Positioned(
              top: -6,
              right: -6,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  icon: Icon(
                      hidden
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      color: AppTheme.onFocal.withValues(alpha: 0.7),
                      size: 22),
                  onPressed: onToggleVisibility,
                  tooltip: hidden ? 'Show' : 'Hide',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A plain card: a status dot + title, the count and amount, and a charcoal
/// round "View" button. Deliberately unremarkable — on a page of twelve of
/// these, colour is reserved for the one block that is the point.
class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.title,
    required this.statusColor,
    required this.count,
    this.rank = 0,
    this.amount,
    this.onView,
  });

  final String title;
  final Color statusColor;

  /// Position in its section, 0 first. Drives which step of the card family
  /// this one sits on — series order IS emphasis order, so a section never
  /// needs a colour per card.
  final int rank;
  final String count;
  final String? amount;
  final VoidCallback? onView;

  static TextStyle get _labelStyle => AppTheme.body(12.5,
      weight: FontWeight.w700, color: AppTheme.inkMuted);

  /// One cell: a caption on the top line, a figure on the bottom line. Both
  /// cells use this so the two lines run straight across the card.
  static Widget _cell({
    required Widget label,
    required String value,
    required Color valueColor,
    required CrossAxisAlignment align,
    required TextAlign textAlign,
  }) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: align,
        children: [
          label,
          const SizedBox(height: 12),
          Text(value,
              maxLines: 1,
              textAlign: textAlign,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.display(26,
                  weight: FontWeight.w800, spacing: -0.6, color: valueColor)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      // Frosted in light mode so the section well reads through it; solid on
      // black, where translucency would just dissolve the card.
      decoration: AppTheme.card(
          radius: 22, translucent: true, fill: AppTheme.cardSurface(rank)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // TWO CELLS, BUILT THE SAME WAY. Both are caption-over-figure, so
            // the captions share a line and the figures share a line — the
            // right cell used to be figure-over-caption, which mirrored the
            // left one and left the two numbers sitting at different heights.
            Expanded(
              child: _cell(
                label: Row(
                  children: [
                    // Flat, not a haloed dot. The old 3px alpha ring left a
                    // 12px mark with only a 6px solid core — soft-UI residue
                    // that reads as mush next to hard-edged blocks.
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: statusColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _labelStyle),
                    ),
                  ],
                ),
                value: amount ?? count,
                valueColor: AppTheme.ink,
                align: CrossAxisAlignment.start,
                textAlign: TextAlign.left,
              ),
            ),
            // The second cell only exists when there are two figures to
            // divide. A card whose only number is the count keeps it in the
            // lead slot rather than pushing it into a cell of its own.
            if (amount != null) ...[
              const SizedBox(width: 14),
              Container(width: 1, color: AppTheme.line),
              const SizedBox(width: 14),
              // An equal share, and its content starts right at the rule.
              // Sized to its own content it hugged the card's far edge, which
              // left a gap between the two figures that changed width with the
              // amount — wide next to ₹0, narrow next to ₹1,21,000 — so the
              // pair never sat still down a column of cards. Two equal columns
              // put the rule in the same place on every card and bring the
              // figures back within reading distance of each other.
              Expanded(
                child: _cell(
                  // Centred in its column rather than pinned to the rule.
                  // Left-aligned it sat hard against the divider with the
                  // whole right half empty behind it; centring spends that
                  // slack on both sides of the figure instead of all of it on
                  // one.
                  label: Text('accounts',
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: _labelStyle),
                  value: count,
                  valueColor: AppTheme.inkFaint,
                  align: CrossAxisAlignment.center,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (onView == null) return card;
    // The whole card is the target. It always was — the arrow badge only ever
    // restated that, and on a page of six cards it was six charcoal blobs
    // competing with the one block that is meant to draw the eye.
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
