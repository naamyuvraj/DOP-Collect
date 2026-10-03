import 'package:flutter/material.dart';

import '../models/account_sort.dart';
import '../theme/app_theme.dart';
import 'press.dart';

/// A horizontal, scrollable row of one-tap sort chips. When [smartLabel] is
/// given, a leading chip represents the screen's default order (a null value);
/// pass null to omit it. Kept deliberately big and legible for thick fingers.
class AccountSortBar extends StatelessWidget {
  const AccountSortBar({
    super.key,
    required this.value,
    required this.onChanged,
    this.smartLabel,
  });

  final AccountSort? value;
  final ValueChanged<AccountSort?> onChanged;
  final String? smartLabel;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child:
            Icon(Icons.swap_vert_rounded, size: 18, color: AppTheme.inkMuted),
      ),
      if (smartLabel != null)
        _chip(smartLabel!, value == null, () => onChanged(null)),
      for (final s in AccountSort.values)
        _chip(s.label, value == s, () => onChanged(s)),
    ];
    // On a desktop the chips fit with room to spare, so they wrap and sit
    // against the left edge — under the search box they filter, and lined up
    // with the table's first column. Scrolled and floating in the middle of a
    // 1,080 px row is a phone control that happens to have been given space.
    if (MediaQuery.of(context).size.width >= kDesktopBreakpoint) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return PressFace(
      onTap: onTap,
      // NO `alignment` here. A Container with an alignment set expands to fill
      // whatever constraints it is given, and only shrink-wraps when those are
      // unbounded. Inside the phone's horizontal scroll strip they ARE
      // unbounded, so it looked harmless — but inside the desktop [Wrap] below
      // the width is bounded, and every chip grew to the full row and stacked
      // one per line. The padding already centres the label.
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      // The chosen chip stands off the strip; the rest stay flat outlines. So
      // only the chosen one has a face to sink; the flat ones recoil instead,
      // which is the whole of PressFace's fallback.
      rest: active ? AppTheme.faceOffsetPressed : 0,
      pressedFace: 0,
      decoration: (face) => AppTheme.card(
          fill: active ? AppTheme.black : AppTheme.surface,
          radius: 20,
          offset: face),
      child: Text(label,
          style: AppTheme.body(12.5,
              weight: FontWeight.w700,
              color: active ? AppTheme.onAccent : AppTheme.ink)),
    );
  }
}
