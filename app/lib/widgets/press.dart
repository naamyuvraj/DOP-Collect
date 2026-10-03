import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Wraps a tappable extruded block so it actually moves under the thumb.
///
/// Every block in this app is drawn with a hard, zero-blur face offset
/// down-right of it. A press shrinks that face AND slides the block the same
/// distance into the gap it just gave up, so the top surface travels while the
/// face's far corner stays nailed to the page — the block sinks rather than
/// slides. Those two numbers are useless apart: shrink the face alone and the
/// block sits still while its shadow twitches; move the block alone and the
/// whole assembly drifts diagonally. Keeping them in one widget is the point.
///
/// A tap can be over in 40ms — press and release land inside a single frame
/// pair and the animation never gets far enough from rest to be seen. That is
/// what "the button doesn't do anything" actually is, so the down state is
/// held for [_minHold] regardless of how fast the finger left.
class PressFace extends StatefulWidget {
  const PressFace({
    super.key,
    required this.decoration,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.rest = AppTheme.faceOffset,
    this.pressedFace = AppTheme.faceOffsetPressed,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.alignment,
    this.enabled = true,
    this.behavior = HitTestBehavior.opaque,
    this.travelDirection = const Offset(1, 1),
    this.clipBehavior = Clip.none,
  });

  /// Built fresh for the current face offset, so the caller keeps ownership of
  /// its own fill, radius and border and this widget only drives the depth.
  final BoxDecoration Function(double face) decoration;
  final Widget child;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The face at rest and while held. [rest] of 0 is a legitimate flat block —
  /// it presses by scaling instead, since there is no depth to give back.
  final double rest;
  final double pressedFace;

  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  /// Separate from a null [onTap] so a busy button can go inert without the
  /// call site having to null out its handler.
  final bool enabled;
  final HitTestBehavior behavior;

  /// Which way the block sinks, as a unit vector. Must match the direction the
  /// face is cast in or the block slides out from under its own shadow — the
  /// round agent button casts straight down, so it travels straight down.
  final Offset travelDirection;

  /// Clips the child to the decoration's border radius, for a block whose
  /// contents run to its edge.
  final Clip clipBehavior;

  @override
  State<PressFace> createState() => _PressFaceState();
}

class _PressFaceState extends State<PressFace> {
  static const _minHold = Duration(milliseconds: 110);
  static const _fade = Duration(milliseconds: 90);

  bool _down = false;
  bool _hover = false;
  final _held = Stopwatch();
  Timer? _release;

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  void _press() {
    _release?.cancel();
    _held
      ..reset()
      ..start();
    setState(() => _down = true);
  }

  /// Lifts now if the finger was down long enough to see, otherwise schedules
  /// the lift for the moment it will have been.
  void _lift() {
    final left = _minHold - _held.elapsed;
    _held.stop();
    if (left <= Duration.zero) {
      setState(() => _down = false);
      return;
    }
    _release = Timer(left, () {
      if (mounted) setState(() => _down = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final live =
        widget.enabled && (widget.onTap != null || widget.onLongPress != null);
    final down = _down && live;

    // POINTER DEVICES GET A FLAT CONTROL.
    //
    // The extrusion above is not decoration — it exists because a thumb covers
    // the thing it is touching, so the block has to MOVE for the press to be
    // confirmed at all. A pointer covers nothing and arrives before the click,
    // so on a desktop the same treatment buys nothing and costs everything:
    // a screen of raised, bouncing blocks is the single loudest "this is a
    // phone app in a window" signal in the UI, and no amount of layout work
    // fixes it while every control still looks pressable by a finger.
    //
    // So the face collapses to zero (the caller's decoration keeps its fill,
    // radius and 1px border — only the hard shadow goes) and the affordance
    // becomes the one a pointer actually has: a cursor change and a hover
    // tint. Nothing above this widget has to know.
    final desktop = MediaQuery.of(context).size.width >= kDesktopBreakpoint;
    final rest = desktop ? 0.0 : widget.rest;
    final pressedFace = desktop ? 0.0 : widget.pressedFace;
    final travel = rest - pressedFace;

    final block = AnimatedContainer(
      duration: _fade,
      curve: Curves.easeOut,
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      alignment: widget.alignment,
      padding: widget.padding,
      clipBehavior: widget.clipBehavior,
      transformAlignment: Alignment.center,
      transform: !down || desktop
          ? Matrix4.identity()
          : travel > 0
              ? Matrix4.translationValues(travel * widget.travelDirection.dx,
                  travel * widget.travelDirection.dy, 0)
              // Nothing to sink into, so it recoils instead. Shallow on
              // purpose: a chip that shrinks visibly reads as a bug.
              : Matrix4.diagonal3Values(0.96, 0.96, 1),
      decoration: widget.decoration(down ? pressedFace : rest),
      // Painted OVER the caller's decoration, so hover works on any fill —
      // white cards, the charcoal CTA, the yellow focal block — without this
      // widget knowing what colour it was handed.
      foregroundDecoration: (desktop && live && (_hover || down))
          ? _wash(widget.decoration(rest), down ? 0.10 : 0.05)
          : null,
      child: widget.child,
    );

    final gesture = GestureDetector(
      behavior: widget.behavior,
      onTapDown: live ? (_) => _press() : null,
      onTapUp: live ? (_) => _lift() : null,
      onTapCancel: live ? _lift : null,
      onTap: live ? widget.onTap : null,
      onLongPress: live ? widget.onLongPress : null,
      child: block,
    );

    if (!desktop || !live) return gesture;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: gesture,
    );
  }

  /// The hover wash has to take the SHAPE of the block it covers, not just its
  /// radius — the round assistant button would otherwise get a square highlight
  /// painted over it, and `borderRadius` is illegal on a circle.
  static BoxDecoration _wash(BoxDecoration base, double alpha) {
    final tint = Colors.white.withValues(alpha: alpha);
    return base.shape == BoxShape.circle
        ? BoxDecoration(color: tint, shape: BoxShape.circle)
        : BoxDecoration(color: tint, borderRadius: base.borderRadius);
  }
}
