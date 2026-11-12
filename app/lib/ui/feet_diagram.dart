import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import 'foot_shape.dart';
import 'tokens.dart';

enum FeetArrow { none, forward, back }

/// Both feet from above, toes up the screen, about one foot-width apart.
/// One foot can be highlighted, with an animated slide forward or back, a
/// buzz, the ankle nodes (USB-C toward the toes), or the stance spacing.
class FeetDiagram extends StatefulWidget {
  const FeetDiagram({
    super.key,
    this.active,
    this.arrow = FeetArrow.none,
    this.showNodes = false,
    this.showStance = false,
    this.buzzing,
    this.height = 250,
  });

  final Role? active;
  final FeetArrow arrow;
  final bool showNodes, showStance;

  /// This foot's node is buzzing (vibration marks beside it).
  final Role? buzzing;
  final double height;

  @override
  State<FeetDiagram> createState() => _FeetDiagramState();
}

class _FeetDiagramState extends State<FeetDiagram> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  bool get _moving => widget.arrow != FeetArrow.none || widget.buzzing != null;

  @override
  void initState() {
    super.initState();
    if (_moving) _anim.repeat();
  }

  @override
  void didUpdateWidget(FeetDiagram old) {
    super.didUpdateWidget(old);
    if (_moving && !_anim.isAnimating) {
      _anim.repeat();
    } else if (!_moving && _anim.isAnimating) {
      _anim.stop();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final words = [
      if (w.active != null) '${w.active == Role.left ? 'Left' : 'Right'} foot highlighted',
      if (w.arrow == FeetArrow.forward) 'sliding forward',
      if (w.arrow == FeetArrow.back) 'coming back',
      if (w.showStance) 'feet parallel, about one foot-width apart',
      if (w.showNodes) 'node L on the left ankle, R on the right, USB-C toward the toes',
    ];
    return Semantics(
      image: true,
      label: 'Both feet from above: ${words.join(', ')}',
      child: SizedBox(
        height: w.height,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) => CustomPaint(
            painter: _FeetPainter(
              active: w.active,
              arrow: w.arrow,
              showNodes: w.showNodes,
              showStance: w.showStance,
              buzzing: w.buzzing,
              t: _anim.value,
              scheme: Theme.of(context).colorScheme,
              textStyle: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
      ),
    );
  }
}

class _FeetPainter extends CustomPainter {
  _FeetPainter({
    required this.active,
    required this.arrow,
    required this.showNodes,
    required this.showStance,
    required this.buzzing,
    required this.t,
    required this.scheme,
    required this.textStyle,
  });

  final Role? active;
  final FeetArrow arrow;
  final bool showNodes, showStance;
  final Role? buzzing;
  final double t;
  final ColorScheme scheme;
  final TextStyle? textStyle;

  static final _outlines = {
    Role.left: soleOutline(left: true),
    Role.right: soleOutline(left: false),
  };
  static final _caps = {for (final e in _outlines.entries) e.key: toeCapOutline(e.value)};

  /// Gap between the feet's centre lines, in foot lengths (one foot-width
  /// between them, as in the stance).
  static const _apart = 0.68;

  /// How far the slide goes, in foot lengths (about 30 cm on a real foot).
  static const _slide = 0.36;

  @override
  void paint(Canvas canvas, Size size) {
    // Room for the slide above the feet.
    final scale = min(size.height / (1 + _slide + 0.12), size.width / (_apart + 0.6));
    final base = Offset(size.width / 2, size.height - scale * 0.56);

    Offset centreOf(Role r) => base + Offset((r == Role.left ? -_apart / 2 : _apart / 2) * scale, 0);
    // Foot (x toe, y dancer's left) to screen: toes up, dancer's left on the left.
    Offset pt(Role r, (double, double) p, {double fwd = 0}) =>
        centreOf(r) + Offset(-p.$2 * scale, -(p.$1 + fwd) * scale);
    Path sole(Role r, {double fwd = 0}) =>
        Path()..addPolygon([for (final p in _outlines[r]!) pt(r, p, fwd: fwd)], true);

    final idle = Paint()..color = scheme.surfaceContainerHighest;
    final idleEdge = Paint()
      ..color = scheme.outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Slide: where the foot goes, and the foot itself moving there and back.
    final r = active;
    double fwd = 0;
    if (r != null && arrow != FeetArrow.none) {
      // Ease out over 70% of the loop, rest at the end.
      final k = Curves.easeInOut.transform((t / 0.7).clamp(0.0, 1.0));
      fwd = arrow == FeetArrow.forward ? k * _slide : (1 - k) * _slide;
      canvas.drawPath(
          sole(r, fwd: arrow == FeetArrow.forward ? _slide : 0),
          Paint()
            ..color = scheme.primary.withValues(alpha: 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }

    for (final f in Role.values) {
      final on = f == r;
      final path = sole(f, fwd: on ? fwd : 0);
      if (on) {
        canvas.drawPath(path, Paint()..color = scheme.primary);
      } else {
        canvas.drawPath(path, idle);
        canvas.drawPath(path, idleEdge);
      }
      // Toe cap: the sole's colour darkened, as on the live view.
      final cap = [for (final p in _caps[f]!) pt(f, p, fwd: on ? fwd : 0)];
      canvas.drawPath(Path()..addPolygon(cap, true),
          Paint()..color = FootColors.cap(on ? scheme.primary : scheme.surfaceContainerHighest));
      if (showNodes) _node(canvas, f, pt, scale, fwd: on ? fwd : 0);
    }

    // The arrow beside the moving foot.
    if (r != null && arrow != FeetArrow.none) {
      final side = r == Role.left ? -1.0 : 1.0; // outside of the foot, on screen
      final x = centreOf(r).dx + side * 0.27 * scale;
      final y0 = base.dy - 0.15 * scale, y1 = base.dy - (0.15 + _slide + 0.2) * scale;
      final (from, to) = arrow == FeetArrow.forward ? (y0, y1) : (y1, y0);
      final p = Paint()
        ..color = scheme.primary
        ..strokeWidth = max(3.0, scale * 0.025)
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(x, from), Offset(x, to), p);
      final dir = (to - from).sign;
      final head = scale * 0.06;
      canvas.drawPath(
          Path()
            ..moveTo(x - head, to - dir * head)
            ..lineTo(x, to)
            ..lineTo(x + head, to - dir * head),
          p..strokeJoin = StrokeJoin.round);
    }

    // Buzz: little arcs either side of the ankle, pulsing.
    final b = buzzing;
    if (b != null) {
      final c = pt(b, (-0.3, 0));
      final pulse = (sin(t * 2 * pi * 4) + 1) / 2;
      final p = Paint()
        ..color = scheme.primary.withValues(alpha: 0.4 + 0.6 * pulse)
        ..strokeWidth = max(2.0, scale * 0.018)
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      for (final k in [0.2, 0.28]) {
        final rect = Rect.fromCircle(center: c, radius: k * scale);
        canvas.drawArc(rect, -0.5, 1.0, false, p);
        canvas.drawArc(rect, pi - 0.5, 1.0, false, p);
      }
    }

    // Stance: one foot-width between the feet, marked across the gap.
    if (showStance) {
      // Across the balls of the feet, where they are widest.
      const at = 0.22;
      final inner = _outlines[Role.left]!.where((p) => p.$1 > 0.12 && p.$1 < 0.32).map((p) => p.$2).reduce(min);
      final y = pt(Role.left, (at, 0)).dy;
      final a = pt(Role.left, (at, inner)).dx + 4, z = pt(Role.right, (at, -inner)).dx - 4;
      final p = Paint()
        ..color = scheme.tertiary
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(a, y), Offset(z, y), p);
      canvas.drawLine(Offset(a, y - 7), Offset(a, y + 7), p);
      canvas.drawLine(Offset(z, y - 7), Offset(z, y + 7), p);
    }
  }

  /// The ankle node from above: long side along the foot, USB-C (a small
  /// tab) toward the toes, and its letter.
  void _node(Canvas canvas, Role f, Offset Function(Role, (double, double), {double fwd}) pt, double scale,
      {double fwd = 0}) {
    final c = pt(f, (-0.3, 0), fwd: fwd);
    final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: 0.13 * scale, height: 0.22 * scale), Radius.circular(0.03 * scale));
    final usb = RRect.fromRectAndRadius(
        Rect.fromCenter(center: c - Offset(0, 0.125 * scale), width: 0.06 * scale, height: 0.03 * scale),
        Radius.circular(0.01 * scale));
    canvas.drawRRect(body.inflate(2), Paint()..color = scheme.surface);
    canvas.drawRRect(usb, Paint()..color = scheme.tertiary);
    canvas.drawRRect(body, Paint()..color = scheme.inverseSurface);
    final tp = TextPainter(
      text: TextSpan(
        text: f == Role.left ? 'L' : 'R',
        style: (textStyle ?? const TextStyle())
            .copyWith(color: scheme.onInverseSurface, fontSize: 0.09 * scale, fontWeight: AppType.heavy, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(_FeetPainter old) =>
      old.t != t ||
      old.active != active ||
      old.arrow != arrow ||
      old.showNodes != showNodes ||
      old.showStance != showStance ||
      old.buzzing != buzzing ||
      old.scheme != scheme;
}
