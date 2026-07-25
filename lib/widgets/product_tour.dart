import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One stop on the guided tour: what to spotlight and what to say about it.
class TourStep {
  const TourStep({
    required this.key,
    required this.title,
    required this.body,
    this.circle = false,
    this.before,
  });

  /// GlobalKey on the widget to highlight.
  final GlobalKey key;
  final String title;
  final String body;

  /// Round spotlight (for circular buttons) instead of a rounded rect.
  final bool circle;

  /// Runs before the step shows — e.g. switch to the tab being described.
  final Future<void> Function()? before;
}

/// Show the guided product tour. Returns when the user finishes or skips.
Future<void> startProductTour(
  BuildContext context,
  List<TourStep> steps,
) async {
  if (steps.isEmpty) return;
  final overlay = Overlay.of(context);
  final done = Completer<void>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _TourView(
      steps: steps,
      onClose: () {
        entry.remove();
        if (!done.isCompleted) done.complete();
      },
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class _TourView extends StatefulWidget {
  const _TourView({required this.steps, required this.onClose});
  final List<TourStep> steps;
  final VoidCallback onClose;

  @override
  State<_TourView> createState() => _TourViewState();
}

class _TourViewState extends State<_TourView> {
  int _i = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _enter(0);
  }

  /// Run the step's `before` (tab switch), then wait for layout so the target's
  /// on-screen rect is valid before we paint the spotlight. Steps whose target
  /// isn't on screen (e.g. an empty Lists tab has no cards) are skipped.
  Future<void> _enter(int i) async {
    if (i >= widget.steps.length) {
      widget.onClose();
      return;
    }
    setState(() => _ready = false);
    final step = widget.steps[i];
    if (step.before != null) await step.before!();
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;

    if (!_isVisible(step.key)) {
      // Nothing to point at — move on rather than spotlighting empty space.
      await _enter(i + 1);
      return;
    }
    setState(() {
      _i = i;
      _ready = true;
    });
  }

  bool _isVisible(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    return box != null && box.hasSize && box.size.width > 0;
  }

  void _next() {
    if (_i + 1 >= widget.steps.length) {
      widget.onClose();
    } else {
      _enter(_i + 1);
    }
  }

  Rect? _targetRect() {
    final ctx = widget.steps[_i].key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final step = widget.steps[_i];
    final raw = _ready ? _targetRect() : null;
    // Fall back to a centred box if the target isn't laid out (never blocks).
    final hole = (raw ?? Rect.fromCenter(
            center: Offset(screen.width / 2, screen.height / 2),
            width: 1,
            height: 1))
        .inflate(step.circle ? 8 : 10);

    final below = hole.center.dy < screen.height / 2;

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _next,
        child: Stack(
          children: [
            // Dimmed backdrop with the target punched out.
            Positioned.fill(
              child: CustomPaint(
                painter: _SpotlightPainter(hole: hole, circle: step.circle),
              ),
            ),
            // Popup card + arrow, placed on the roomier side of the target.
            Positioned(
              left: 18,
              right: 18,
              top: below ? hole.bottom + 14 : null,
              bottom: below ? null : (screen.height - hole.top) + 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (below) _arrow(hole, screen, up: true),
                  _card(step),
                  if (!below) _arrow(hole, screen, up: false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Little triangle nudged horizontally to point at the spotlight.
  Widget _arrow(Rect hole, Size screen, {required bool up}) {
    const w = 18.0;
    final dx = (hole.center.dx - 18 - w / 2).clamp(6.0, screen.width - 36 - w);
    return Padding(
      padding: EdgeInsets.only(left: dx),
      child: Align(
        alignment: Alignment.centerLeft,
        child: CustomPaint(
          size: const Size(w, 9),
          painter: _ArrowPainter(up: up),
        ),
      ),
    );
  }

  Widget _card(TourStep step) {
    final last = _i == widget.steps.length - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Color(0x40000000), blurRadius: 30, offset: Offset(0, 12)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(step.title,
              style: AppTheme.display(17, weight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(step.body,
              style: AppTheme.body(13.5, color: AppTheme.inkMuted, height: 1.45)),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('${_i + 1} of ${widget.steps.length}',
                  style: AppTheme.body(12, color: AppTheme.inkFaint)),
              const Spacer(),
              if (!last)
                TextButton(
                  onPressed: widget.onClose,
                  child: Text('Skip',
                      style: AppTheme.body(13, color: AppTheme.inkMuted)),
                ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _next,
                child: Text(last ? 'Done' : 'Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Paints the scrim and clears a hole over the highlighted widget.
class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({required this.hole, required this.circle});
  final Rect hole;
  final bool circle;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(bounds, Paint()..color = const Color(0xB3000000));
    final clear = Paint()..blendMode = BlendMode.clear;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.9);
    if (circle) {
      final r = hole.longestSide / 2;
      canvas.drawCircle(hole.center, r, clear);
      canvas.restore();
      canvas.drawCircle(hole.center, r, ring);
    } else {
      final rr = RRect.fromRectAndRadius(hole, const Radius.circular(16));
      canvas.drawRRect(rr, clear);
      canvas.restore();
      canvas.drawRRect(rr, ring);
    }
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.circle != circle;
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({required this.up});
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path();
    if (up) {
      p.moveTo(size.width / 2, 0);
      p.lineTo(size.width, size.height);
      p.lineTo(0, size.height);
    } else {
      p.moveTo(0, 0);
      p.lineTo(size.width, 0);
      p.lineTo(size.width / 2, size.height);
    }
    p.close();
    canvas.drawPath(p, Paint()..color = AppTheme.surface);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.up != up;
}
