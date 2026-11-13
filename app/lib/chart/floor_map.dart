import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ble/protocol.dart';
import '../models/preset.dart';
import '../ui/style.dart';
import 'floor_plan.dart';

/// Foot colours on the floor map: one per foot, on the dark stage.
const floorLeft = Color(0xFFF472B6), floorRight = Color(0xFF38BDF8); // left pink, right blue
Color floorColor(Role f) => f == Role.left ? floorLeft : floorRight;

/// Where the feet go: a dance floor seen from behind and above the dancer,
/// two footprints that glide to their next spot on the beat, and the next
/// landing spots as numbered outlines with an arrow. A static reference worked
/// out from the routine ([FloorPlan]), not from the sensors.
class FloorMap extends StatefulWidget {
  const FloorMap({super.key, required this.preset, required this.beat, this.repaint, this.caption = true});

  final Preset preset;

  /// The current beat (1-based, fractional), read once a frame.
  final double Function() beat;

  /// Repaints the map (e.g. the step chart's controller, which ticks each frame).
  final Listenable? repaint;

  /// The next step's name under the floor.
  final bool caption;

  @override
  State<FloorMap> createState() => _FloorMapState();
}

class _FloorMapState extends State<FloorMap> {
  late FloorPlan _plan = FloorPlan(widget.preset);

  @override
  void didUpdateWidget(FloorMap old) {
    super.didUpdateWidget(old);
    // A tempo change keeps the steps (and so the plan).
    if (!identical(old.preset.steps, widget.preset.steps)) _plan = FloorPlan(widget.preset);
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Floor map: where each foot steps next, seen from behind you',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.lg),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _FloorPainter(_plan, widget.beat, widget.repaint, widget.caption),
              size: Size.infinite,
            ),
          ),
        ),
      );
}

/// The floor map playing a routine's pattern on its own clock, on a loop: the
/// routine screen's preview.
class FloorMapPreview extends StatefulWidget {
  const FloorMapPreview({super.key, required this.preset, this.tempo = 1.0});
  final Preset preset;
  final double tempo;

  @override
  State<FloorMapPreview> createState() => _FloorMapPreviewState();
}

class _FloorMapPreviewState extends State<FloorMapPreview> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _tick = ValueNotifier<Duration>(Duration.zero);
  late FloorPlan _plan = FloorPlan(widget.preset);
  Duration _from = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) => _tick.value = d)..start();
  }

  @override
  void didUpdateWidget(FloorMapPreview old) {
    super.didUpdateWidget(old);
    if (old.preset != widget.preset) {
      _plan = FloorPlan(widget.preset);
      _from = _tick.value; // a new routine starts from its first step
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tick.dispose();
    super.dispose();
  }

  double _beat() {
    if (MediaQuery.of(context).disableAnimations) return 0.5;
    final elapsed = (_tick.value - _from).inMicroseconds / 6e7 * widget.preset.bpm * widget.tempo;
    // The pattern, then a beat's rest; it starts as the first swing begins.
    final cycle = _plan.loopBeats + 1;
    return elapsed % cycle + 0.4;
  }

  @override
  Widget build(BuildContext context) => FloorMap(preset: widget.preset, beat: _beat, repaint: _tick);
}

class _FloorPainter extends CustomPainter {
  _FloorPainter(this.plan, this.beat, Listenable? repaint, this.caption) : super(repaint: repaint);

  final FloorPlan plan;
  final double Function() beat;
  final bool caption;

  // ---- camera ----------------------------------------------------------------
  // A pinhole above and behind the dancer, looking forward and down: far
  // floor is smaller and higher. Straight lines stay straight.
  static const _dist = 3.2; // metres to the focus
  double _tilt = 0.86; // rad from straight down: steeper in a tall panel
  late Offset _cam; // floor point at the focus
  late Offset _origin; // its screen position
  late double _k; // px per metre at the focus

  Offset _proj(Offset p) {
    final r = p - _cam;
    final z = _dist + r.dy * sin(_tilt);
    final s = _k * _dist / z;
    return _origin + Offset(r.dx * s, -r.dy * cos(_tilt) * s);
  }

  /// The projection near [p] as an affine map from floor metres to screen.
  Matrix4 _affine(Offset p) {
    const h = 0.01;
    final o = _proj(p), ex = (_proj(p.translate(h, 0)) - o) / h, ey = (_proj(p.translate(0, h)) - o) / h;
    return Matrix4(ex.dx, ex.dy, 0, 0, ey.dx, ey.dy, 0, 0, 0, 0, 1, 0, o.dx, o.dy, 0, 1);
  }

  /// [path] (floor metres, around the origin) placed at [p], lifted by [lift].
  Path _place(Path path, Offset p, {double lift = 0}) {
    final m = _affine(p);
    if (lift > 0) {
      final o = _proj(p);
      final s = 1 + 0.14 * lift;
      m.setFrom(Matrix4.identity()
        ..translateByDouble(o.dx, o.dy - lift * _k * 0.11, 0, 1)
        ..scaleByDouble(s, s, 1, 1)
        ..translateByDouble(-o.dx, -o.dy, 0, 1)
        ..multiply(m));
    }
    return path.transform(m.storage);
  }

  // ---- shapes ----------------------------------------------------------------

  static const _footLen = 0.27;

  /// A shoe sole in metres, toe toward +y, for the right foot (big toe at -x).
  static final Path _rightSole = () {
    Offset u(double x, double y) => Offset(x * _footLen, y * _footLen);
    final a = u(0, -0.5);
    final p = Path()..moveTo(a.dx, a.dy);
    void c(List<double> v) {
      final p1 = u(v[0], v[1]), p2 = u(v[2], v[3]), p3 = u(v[4], v[5]);
      p.cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy);
    }

    c([0.13, -0.50, 0.15, -0.36, 0.145, -0.22]); // outer heel
    c([0.14, -0.05, 0.195, 0.06, 0.195, 0.21]); // outer arch to the ball
    c([0.195, 0.40, 0.10, 0.50, -0.02, 0.50]); // little toe round to the tip
    c([-0.14, 0.50, -0.205, 0.38, -0.205, 0.22]); // big toe
    c([-0.205, 0.06, -0.10, -0.02, -0.11, -0.18]); // inner arch
    c([-0.12, -0.36, -0.12, -0.50, 0.0, -0.50]); // inner heel
    return p..close();
  }();
  static final Path _leftSole = _rightSole.transform((Matrix4.identity()..scaleByDouble(-1, 1, 1, 1)).storage);
  static Path _sole(Role f) => f == Role.left ? _leftSole : _rightSole;

  static Path _ring(double r) => Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: r));

  // ---- paint -----------------------------------------------------------------

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final b = beat();
    final l = plan.foot(Role.left, b), r = plan.foot(Role.right, b);
    final next = plan.upcoming(b, 3);

    // Frame the feet and where the next step goes, a little ahead of centre.
    var mid = (l.pos + r.pos) / 2;
    if (next.isNotEmpty) mid = Offset.lerp(mid, (next.first.to + (next.first.foot == Role.left ? r.pos : l.pos)) / 2, 0.3)!;
    _cam = mid.translate(0, 0.08);
    // Zoom to the floor this routine covers (the camera follows the feet, so
    // most of it, not all of it), looking more from above in a tall panel.
    final tall = size.height > size.width * 1.1;
    _tilt = tall ? 0.6 : 0.86;
    final ext = plan.extent;
    final needW = (ext.width * 0.7 + 0.55).clamp(1.0, 1.7);
    final needH = (ext.height * 0.7 + 0.65).clamp(0.85, 1.4) * cos(_tilt) * 1.3;
    _k = min(size.width / needW, size.height / needH);
    _origin = Offset(size.width / 2, size.height * (tall ? 0.52 : 0.55));

    _stage(canvas, size);
    _grid(canvas, size);

    // Landing ripples under everything that stands.
    for (final m in plan.landedWithin(b, 0.6)) {
      final a = (b - m.beat) / 0.6;
      canvas.drawPath(
          _place(_ring(0.10 + 0.22 * Curves.easeOut.transform(a)), m.to),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 * (1 - a) + 0.5
            ..color = floorColor(m.foot).withValues(alpha: 0.55 * (1 - a)));
    }

    // The next landing spots: the first one bright with its arrow, the rest faint.
    final pulse = 0.5 + 0.5 * cos(2 * pi * (b - b.floorToDouble()));
    for (var k = next.length - 1; k >= 0; k--) {
      final m = next[k];
      final standing = m.foot == Role.left ? l : r;
      _ghost(canvas, m, k, pulse);
      if (k < 2) _arrow(canvas, standing.swinging ? standing.move!.from : standing.pos, m, k == 0 ? 1.0 : 0.45, b);
    }

    // The feet: the planted one first, the swinging one on top.
    final feet = [(Role.left, l), (Role.right, r)]..sort((a, c) => a.$2.lift.compareTo(c.$2.lift));
    final upNext = next.isEmpty ? null : next.first.foot;
    for (final (f, p) in feet) {
      _foot(canvas, f, p, active: p.swinging || f == upNext, pulse: f == upNext && !p.swinging ? pulse : 0);
    }

    _hud(canvas, size, next.isEmpty ? null : next.first, l.swinging ? l : (r.swinging ? r : null));
  }

  void _stage(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0B0E1F), Color(0xFF1A1F3D), Color(0xFF141831)],
            stops: [0, 0.55, 1],
          ).createShader(rect));
    // A soft spotlight on the floor round the dancer.
    final spot = _place(_ring(1.1), _cam);
    final c = _proj(_cam);
    canvas.drawPath(
        spot,
        Paint()
          ..shader = ui.Gradient.radial(c, spot.getBounds().width / 2, [
            const Color(0x33A5B4FC),
            const Color(0x0FA5B4FC),
            const Color(0x00A5B4FC),
          ], [
            0,
            0.55,
            1
          ])
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
  }

  void _grid(Canvas canvas, Size size) {
    const tile = 0.5;
    final x0 = (_cam.dx / tile).floor() - 5, y0 = (_cam.dy / tile).floor() - 3;
    final fill = Paint()..color = const Color(0x0AFFFFFF);
    for (var i = x0; i < x0 + 10; i++) {
      for (var j = y0; j < y0 + 8; j++) {
        if ((i + j).isEven) continue;
        final q = [
          _proj(Offset(i * tile, j * tile)),
          _proj(Offset((i + 1) * tile, j * tile)),
          _proj(Offset((i + 1) * tile, (j + 1) * tile)),
          _proj(Offset(i * tile, (j + 1) * tile)),
        ];
        canvas.drawPath(Path()..addPolygon(q, true), fill);
      }
    }
    final line = Paint()
      ..strokeWidth = 1
      ..color = const Color(0x17FFFFFF);
    for (var i = x0; i <= x0 + 10; i++) {
      canvas.drawLine(_proj(Offset(i * tile, y0 * tile)), _proj(Offset(i * tile, (y0 + 8) * tile)), line);
    }
    for (var j = y0; j <= y0 + 8; j++) {
      canvas.drawLine(_proj(Offset(x0 * tile, j * tile)), _proj(Offset((x0 + 10) * tile, j * tile)), line);
    }
    // Fade the far floor into the dark.
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [Color(0xFF0B0E1F), Color(0x000B0E1F)],
          ).createShader(rect));
  }

  void _foot(Canvas canvas, Role f, FootPose p, {required bool active, required double pulse}) {
    final color = floorColor(f);
    final floorPath = _place(_sole(f), p.pos);
    final path = _place(_sole(f), p.pos, lift: p.lift);
    // Shadow stays on the floor and softens as the foot rises.
    canvas.drawPath(
        floorPath.shift(Offset(2, 3 + 4 * p.lift)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.5 - 0.25 * p.lift.clamp(0, 1))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 7 * p.lift));
    if (active) {
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.35 + 0.35 * max(p.lift.clamp(0.0, 1.0), pulse))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    }
    final bounds = path.getBounds();
    final hsl = HSLColor.fromColor(color);
    canvas.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.linear(bounds.bottomCenter, bounds.topCenter, [
            hsl.withLightness((hsl.lightness - 0.12).clamp(0, 1)).toColor(),
            hsl.withLightness((hsl.lightness + 0.10).clamp(0, 1)).toColor(),
          ]));
    // A soft highlight across the ball of the foot, then the rim.
    canvas.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.radial(
              Offset.lerp(bounds.center, bounds.topCenter, 0.45)!, bounds.width * 0.6, [
            Colors.white.withValues(alpha: 0.35),
            Colors.white.withValues(alpha: 0),
          ]));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withValues(alpha: active ? 0.85 : 0.45));
    _text(canvas, f == Role.left ? 'L' : 'R', bounds.center, (_k * 0.075).clamp(10, 20),
        color: Colors.white, weight: FontWeight.w800, shadow: true);
  }

  void _ghost(Canvas canvas, FloorMove m, int k, double pulse) {
    final color = floorColor(m.foot);
    final strength = k == 0 ? 0.65 + 0.35 * pulse : (k == 1 ? 0.45 : 0.22);
    final path = _place(_sole(m.foot), m.to);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.10 + 0.12 * strength));
    _dashed(
        canvas,
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: strength),
        dash: 6,
        gap: 4);
    // The order of the coming steps, just ahead of the toe.
    final at = _proj(m.to.translate(0, _footLen * 0.75));
    final rad = (_k * 0.045).clamp(9.0, 14.0);
    canvas.drawCircle(at, rad, Paint()..color = color.withValues(alpha: k == 0 ? 1 : 0.55));
    _text(canvas, '${k + 1}', at, rad * 1.15, color: const Color(0xFF0B0E1F), weight: FontWeight.w800);
  }

  void _arrow(Canvas canvas, Offset from, FloorMove m, double strength, double b) {
    final to = m.to;
    if ((to - from).distance < 0.05) {
      if (m.cls == StepClass.kick || m.cls == StepClass.inPlace) {
        // No travel: a ring that says "lift and put down here".
        canvas.drawPath(
            _place(_ring(0.19), to),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = floorColor(m.foot).withValues(alpha: 0.5 * strength));
      }
      return;
    }
    // Crosses swing round the standing foot: in front of it or behind it.
    final d = to - from;
    final c = switch (m.cls) {
      StepClass.cross => (from + to) / 2 + const Offset(0, 0.16),
      StepClass.crossBehind => (from + to) / 2 + const Offset(0, -0.16),
      // As the foot moves: level first, then the slide in.
      StepClass.sideIn => Offset(from.dx + d.dx * 0.25, to.dy),
      _ => (from + to) / 2 + Offset(-d.dy, d.dx) / max(d.distance, 1e-6) * 0.03,
    };
    final pts = <Offset>[];
    // From the edge of the standing foot to the edge of the outline.
    final len = d.distance;
    final t0 = (_footLen * 0.42 / len).clamp(0.0, 0.4), t1 = (1 - _footLen * 0.5 / len).clamp(t0 + 0.15, 1.0);
    const n = 24;
    for (var i = 0; i <= n; i++) {
      final t = t0 + (t1 - t0) * i / n;
      final q = from * ((1 - t) * (1 - t)) + c * (2 * (1 - t) * t) + to * (t * t);
      pts.add(_proj(q));
    }
    final color = floorColor(m.foot).withValues(alpha: 0.9 * strength);
    final path = Path()..addPolygon(pts, false);
    // Marching dashes, a beat per cycle: reads as "this way".
    _dashed(
        canvas,
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..color = color,
        dash: 9,
        gap: 7,
        phase: -(b % 1) * 16);
    final tip = pts.last, dir = (pts.last - pts[pts.length - 3]);
    final u = dir / max(dir.distance, 1e-6), nrm = Offset(-u.dy, u.dx);
    final s = (_k * 0.05).clamp(8.0, 14.0);
    canvas.drawPath(
        Path()..addPolygon([tip + u * s, tip - u * s * 0.4 + nrm * s * 0.8, tip - u * s * 0.4 - nrm * s * 0.8], true),
        Paint()..color = color);
  }

  void _hud(Canvas canvas, Size size, FloorMove? next, FootPose? swinging) {
    // Which way the dancer faces.
    final top = Offset(size.width / 2, 18);
    _text(canvas, 'FRONT', top.translate(0, 2), 11, color: Colors.white.withValues(alpha: 0.55), weight: FontWeight.w700, spacing: 2);
    canvas.drawPath(
        Path()..addPolygon([top.translate(0, -13), top.translate(-5, -7), top.translate(5, -7)], true),
        Paint()..color = Colors.white.withValues(alpha: 0.55));
    if (!caption) return;
    final m = swinging?.move ?? next;
    if (m == null) return;
    final label = '${m.foot == Role.left ? 'Left' : 'Right'} · ${stepLabel(m.cls, m.foot)}';
    final tp = _layout(label, 15, color: Colors.white, weight: FontWeight.w700);
    final pill = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size.width / 2, size.height - 24), width: tp.width + 40, height: 32),
        const Radius.circular(16));
    canvas.drawRRect(pill, Paint()..color = const Color(0xCC0B0E1F));
    canvas.drawRRect(
        pill,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = floorColor(m.foot).withValues(alpha: 0.8));
    canvas.drawCircle(pill.center.translate(-tp.width / 2 - 10, 0), 4, Paint()..color = floorColor(m.foot));
    tp.paint(canvas, pill.center.translate(-tp.width / 2 + 6, -tp.height / 2));
  }

  // ---- helpers ----------------------------------------------------------------

  static void _dashed(Canvas canvas, Path path, Paint paint, {required double dash, required double gap, double phase = 0}) {
    final period = dash + gap;
    for (final metric in path.computeMetrics()) {
      var d = phase % period;
      if (d > 0) d -= period;
      while (d < metric.length) {
        final a = max(0.0, d), e = min(metric.length, d + dash);
        if (e > a) canvas.drawPath(metric.extractPath(a, e), paint);
        d += period;
      }
    }
  }

  static final _cache = <(String, double, int, int), TextPainter>{};

  static TextPainter _layout(String s, double size, {required Color color, FontWeight weight = FontWeight.w600, double spacing = 0}) {
    final key = (s, size.roundToDouble(), color.toARGB32(), weight.value + (spacing * 10).round());
    if (_cache.length > 200) _cache.clear();
    return _cache[key] ??= TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(color: color, fontSize: size.roundToDouble(), fontWeight: weight, letterSpacing: spacing, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  static void _text(Canvas canvas, String s, Offset center, double size,
      {required Color color, FontWeight weight = FontWeight.w600, double spacing = 0, bool shadow = false}) {
    final tp = _layout(s, size, color: color, weight: weight, spacing: spacing);
    final at = center - Offset(tp.width / 2, tp.height / 2);
    if (shadow) _layout(s, size, color: const Color(0x99000000), weight: weight, spacing: spacing).paint(canvas, at.translate(0, 1));
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_FloorPainter old) => old.plan != plan || old.caption != caption;
}
