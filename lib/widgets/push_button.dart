import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A tactile button: a solid block sitting on its own hard, zero-blur
/// extruded face, which shrinks under the thumb so the block presses into the
/// page.
///
/// The dashboard's depth vocabulary is half unavailable here — `--ex: 8px` on
/// hover is a mouse affordance — so only the press state survives.
class PushButton extends StatefulWidget {
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

  @override
  State<PushButton> createState() => _PushButtonState();
}

class _PushButtonState extends State<PushButton> {
  bool _down = false;

  Color get _color => widget.color ?? AppTheme.black;
  Color get _foreground => widget.foreground ?? AppTheme.onAccent;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final pressed = _down && enabled;
    // On light, a mid-grey fill reads as "off". On dark that same grey is
    // LIGHTER than the ground and reads as enabled, so recede instead.
    final disabledFill = AppTheme.isDark ? AppTheme.line : AppTheme.surfaceSoft;
    final fg = enabled ? _foreground : AppTheme.inkFaint;
    const travel = AppTheme.buttonFace - AppTheme.faceOffsetPressed;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: widget.onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 70),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(
            pressed ? travel : 0, pressed ? travel : 0, 0),
        decoration: AppTheme.card(
          fill: enabled ? _color : disabledFill,
          radius: widget.radius,
          offset: enabled
              ? (pressed ? AppTheme.faceOffsetPressed : AppTheme.buttonFace)
              : 0,
        ),
        padding: widget.padding,
        child: DefaultTextStyle(
          style: AppTheme.body(15, weight: FontWeight.w700, color: fg),
          child: IconTheme(
            data: IconThemeData(color: fg, size: 20),
            child: widget.expand
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [Flexible(child: Center(child: widget.child))],
                  )
                : widget.child,
          ),
        ),
      ),
    );
  }
}
