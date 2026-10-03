import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'press.dart';

/// A tactile button: a solid block sitting on its own hard, zero-blur
/// extruded face, which shrinks under the thumb so the block presses into the
/// page.
///
/// The dashboard's depth vocabulary is half unavailable here — `--ex: 8px` on
/// hover is a mouse affordance — so only the press state survives.
class PushButton extends StatelessWidget {
  const PushButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.color,
    this.foreground,
    this.radius = AppTheme.cardRadius,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
    this.expand = true,
  });

  final Widget child;
  final VoidCallback? onPressed;

  /// Defaults to the charcoal solid / its matching foreground. Null rather
  /// than a const default so the pair follows the theme — on dark the solid
  /// inverts to near-white with charcoal type.
  final Color? color;
  final Color? foreground;
  final double radius;
  final EdgeInsets padding;
  final bool expand;

  Color get _color => color ?? AppTheme.black;
  Color get _foreground => foreground ?? AppTheme.onAccent;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    // On light, a mid-grey fill reads as "off". On dark that same grey is
    // LIGHTER than the ground and reads as enabled, so recede instead.
    final disabledFill = AppTheme.isDark ? AppTheme.line : AppTheme.surfaceSoft;
    final fg = enabled ? _foreground : AppTheme.inkFaint;
    return PressFace(
      onTap: onPressed,
      enabled: enabled,
      // A disabled button is flat on the page: no face to give back, and no
      // recoil either, so it is pinned at rest on both counts.
      rest: enabled ? AppTheme.buttonFace : 0,
      pressedFace: enabled ? AppTheme.faceOffsetPressed : 0,
      padding: padding,
      decoration: (face) => AppTheme.card(
        fill: enabled ? _color : disabledFill,
        radius: radius,
        offset: face,
      ),
      child: DefaultTextStyle(
        style: AppTheme.body(15, weight: FontWeight.w700, color: fg),
        child: IconTheme(
          data: IconThemeData(color: fg, size: 20),
          child: expand
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [Flexible(child: Center(child: child))],
                )
              : child,
        ),
      ),
    );
  }
}
