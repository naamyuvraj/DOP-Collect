import 'package:flutter/material.dart';

import '../models/account_sort.dart';
import '../theme/app_theme.dart';

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
      const Padding(
        padding: EdgeInsets.only(right: 4),
        child: Icon(Icons.swap_vert_rounded, size: 18, color: AppTheme.inkMuted),
      ),
      if (smartLabel != null)
        _chip(smartLabel!, value == null, () => onChanged(null)),
      for (final s in AccountSort.values)
        _chip(s.label, value == s, () => onChanged(s)),
    ];
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppTheme.black : AppTheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? AppTheme.black : AppTheme.line),
        ),
        child: Text(label,
            style: AppTheme.body(12.5,
                weight: FontWeight.w700,
                color: active ? Colors.white : AppTheme.ink)),
      ),
    );
  }
}
