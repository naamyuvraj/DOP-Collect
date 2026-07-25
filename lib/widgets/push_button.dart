import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A tactile 3D button: sits on a solid darker "edge" shadow and presses down
/// into it on tap, giving a physical, key-like feel. Used for primary CTAs.
class PushButton extends StatefulWidget {
  const PushButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.color = AppTheme.black,
    this.foreground = Colors.white,
    this.radius = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
    this.expand = true,
    this.depth = 5,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final Color color;
  final Color foreground;
  final double radius;
  final EdgeInsets padding;
  final bool expand;
  final double depth;

  @override
  State<PushButton> createState() => _PushButtonState();
}

class _PushButtonState extends State<PushButton> {
  bool _down = false;

  Color get _edge => Color.alphaBlend(Colors.black.withValues(alpha: 0.28), widget.color);

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final pressed = _down && enabled;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: widget.onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, pressed ? widget.depth : 0, 0),
        decoration: BoxDecoration(
          color: enabled ? widget.color : AppTheme.inkFaint,
          borderRadius: BorderRadius.circular(widget.radius),
          boxShadow: [
            // The solid 3D edge underneath.
            BoxShadow(
              color: enabled ? _edge : Colors.transparent,
              offset: Offset(0, pressed ? 0 : widget.depth),
              blurRadius: 0,
            ),
            // Soft ambient shadow on the canvas.
            if (enabled && !pressed)
              BoxShadow(
                  color: widget.color.withValues(alpha: 0.25),
                  offset: const Offset(0, 8),
                  blurRadius: 16),
          ],
        ),
        padding: widget.padding,
        child: DefaultTextStyle(
          style: AppTheme.body(15,
              weight: FontWeight.w700, color: widget.foreground),
          child: IconTheme(
            data: IconThemeData(color: widget.foreground, size: 20),
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
