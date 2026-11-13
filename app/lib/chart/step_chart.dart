import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import '../models/preset.dart';
import '../ui/style.dart';

/// What the step chart shows. The dance screen moves [nowBeat] once a frame
/// (from a Ticker) and adds verdicts and hit flashes as they arrive; only the
/// chart repaints, not the screen around it.
class StepChartController extends ChangeNotifier {
  StepChartController(this.preset);

  /// The routine. Its tempo may change (Practice slow-down); the steps do not.
  Preset preset;

  /// Current beat, 1-based and fractional.
  double nowBeat = 0;

  /// Verdict per step index into [Preset.steps], once one arrives. The
  /// session's own map, read only here (not copied per event).
  Map<int, Verdict> verdicts = const {};

  /// Position in [Preset.beatOrder] of the first step not yet behind the now
  /// line, so finding the next step does not walk the whole routine each frame.
  int _cursor = 0;

  final _clock = Stopwatch()..start();
  final _hits = <_Hit>[];
  Verdict? _lastVerdict;

  /// What a screen reader says about the chart: the next step and the last
  /// verdict. Changes once a step, not once a frame.
  final spoken = ValueNotifier<String>('');

  /// Beats before the landing at which a step's swing starts (the chart's
  /// dashed lift line; the floor map lifts the foot then too).
  static const liftBeats = 0.5;

  /// How long a lane wash and a pop label last.
  static const washMs = 250, popMs = 900;

  void tick(double beat) {
    nowBeat = beat;
    _hits.removeWhere((h) => _clock.elapsedMilliseconds - h.atMs > popMs);
    _updateSpoken();
    notifyListeners();
  }

  /// [v] is kept by reference: the caller changes it and calls this again.
  void setVerdicts(Map<int, Verdict> v) {
    verdicts = v;
    _updateSpoken();
    notifyListeners();
  }

  /// Steps still pending at the now line, in beat order (a quarter beat of grace).
  bool _pending(PresetStep s) => s.beat - nowBeat > -0.25;

  void _updateSpoken() {
    final steps = preset.steps;
    final order = preset.beatOrder;
    // Time runs forward except on a rewind: then start the cursor over.
    if (_cursor > 0 && _cursor <= order.length && _pending(steps[order[_cursor - 1]])) _cursor = 0;
    while (_cursor < order.length && !_pending(steps[order[_cursor]])) {
      _cursor++;
    }
    String? next;
    for (var k = _cursor; k < order.length; k++) {
      final i = order[k];
      final s = steps[i];
      if (s.stepClass == StepClass.none || verdicts[i] != null) continue;
      next = 'Next: ${footName(s.foot).toLowerCase()} foot ${stepLabel(s.stepClass, s.foot)}, bar ${barOf(s.beat, preset.beatsPerBar)}';
      break;
    }
    final last = _lastVerdict;
    spoken.value = [next ?? 'No more steps', if (last != null) 'Last step: ${last.label}'].join('. ');
  }

  @override
  void dispose() {
    spoken.dispose();
    super.dispose();
  }

  /// Hits still washing or popping: the chart needs frames until they fade.
  bool get animating => _hits.isNotEmpty;

  /// Watch-first mode: pop the step's name at the now line in the theme colour,
  /// with no verdict.
  void cue(Role foot, String label) {
    _hits.removeWhere((h) => h.foot == foot);
    _hits.add(_Hit(foot, null, label, _clock.elapsedMilliseconds));
    notifyListeners();
  }

  /// Flash [foot]'s lane in the verdict colour and pop a label at the now line.
  void hit(Role foot, Verdict v, {int timingErrMs = 0}) {
    final label = switch (v) {
      Verdict.correct => null, // a check mark
      Verdict.offBeat => timingErrMs > 0 ? 'late' : 'early',
      Verdict.wrongStep => 'wrong',
      Verdict.missed => 'miss',
      _ => null,
    };
    if (v == Verdict.extra || v == Verdict.unjudged) return;
    _hits.removeWhere((h) => h.foot == foot);
    _hits.add(_Hit(foot, v, label, _clock.elapsedMilliseconds));
    _lastVerdict = v;
    _updateSpoken();
    notifyListeners();
  }
}

class _Hit {
  _Hit(this.foot, this.verdict, this.label, this.atMs);
  final Role foot;

  /// Null for a watch-first cue.
  final Verdict? verdict;
  final String? label;
  final int atMs;
}

/// Scrolling step chart: two lanes (L, R), upcoming steps scroll down toward
/// the "now" line. The next step in each lane is drawn larger, with a halo.
class StepChart extends StatelessWidget {
  const StepChart({
    super.key,
    required this.controller,
    this.beatsVisibleAhead = 4,
    this.beatsVisibleBehind = 1.5,
  });

  final StepChartController controller;
  final double beatsVisibleAhead;
  final double beatsVisibleBehind;

  /// Lane header height for a chart of [size]; it scales with the chart so it
  /// reads from across a room. Overlays dock just under it.
  static double headerHeight(Size size) => (size.shortestSide * 0.08).clamp(40.0, 68.0);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller.spoken,
      builder: (context, spoken, child) => Semantics(liveRegion: true, label: spoken, child: child),
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _StepChartPainter(
            c: controller,
            ahead: beatsVisibleAhead,
            behind: beatsVisibleBehind,
            theme: Theme.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _StepChartPainter extends CustomPainter {
  _StepChartPainter(
      {required this.c, required this.ahead, required this.behind, required this.theme, required this.textScaler})
      : super(repaint: c);

  final StepChartController c;
  final double ahead, behind;
  final ThemeData theme;

  /// The user's text size, for the step captions and pop labels (already
  /// sized from the chart, so it is capped to keep them inside the lane).
  final TextScaler textScaler;

  static const _gap = 10.0;

  ColorScheme get _scheme => theme.colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = _scheme;
    final laneW = (size.width - _gap) / 2;
    double laneX(Role f) => f == Role.left ? 0 : laneW + _gap;
    final headerH = StepChart.headerHeight(size);
    final bodyH = size.height - headerH;
    final pxPerBeat = bodyH / (ahead + behind);
    final nowY = size.height - behind * pxPerBeat;
    final nowBeat = c.nowBeat;
    final nowMs = c._clock.elapsedMilliseconds;
    final r = min(laneW * 0.3, pxPerBeat * 0.36).clamp(14.0, double.infinity);
    final lanes = [for (final f in Role.values) (f, Rect.fromLTWH(laneX(f), 0, laneW, size.height))];

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // 1. Lanes, hit zone and beat grid (bar lines stronger).
    for (final (_, rect) in lanes) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(Radii.lg)), Paint()..color = scheme.surfaceContainerLow);
      canvas.drawRect(Rect.fromLTRB(rect.left, nowY - pxPerBeat * 0.25, rect.right, nowY + pxPerBeat * 0.25),
          Paint()..color = scheme.primary.withValues(alpha: 0.07));
    }
    for (var b = (nowBeat - behind).ceil(); b <= nowBeat + ahead; b++) {
      final y = nowY - (b - nowBeat) * pxPerBeat;
      if (y < headerH) continue;
      final barLine = (b - 1) % c.preset.beatsPerBar == 0;
      final p = Paint()
        ..color = scheme.outlineVariant.withValues(alpha: barLine ? 0.9 : 0.45)
        ..strokeWidth = barLine ? 2 : 1;
      for (final (_, rect) in lanes) {
        canvas.drawLine(Offset(rect.left + 12, y), Offset(rect.right - 12, y), p);
      }
    }

    // 2. Lane washes for fresh verdicts.
    for (final h in c._hits) {
      final age = nowMs - h.atMs;
      if (age > StepChartController.washMs) continue;
      final rect = lanes[h.foot.index].$2;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(Radii.lg)),
          Paint()..color = _hitColor(h).withValues(alpha: 0.28 * (1 - age / StepChartController.washMs)));
    }

    // When to move: lift as a step crosses the dashed line (half a beat to go),
    // land as it reaches the solid line. The beat is the landing.
    final liftY = nowY - StepChartController.liftBeats * pxPerBeat;
    for (final (_, rect) in lanes) {
      if (liftY > headerH + 4) {
        for (var x = rect.left + 12; x < rect.right - 12; x += 14) {
          canvas.drawLine(
              Offset(x, liftY),
              Offset(min(x + 7, rect.right - 12), liftY),
              Paint()
                ..color = scheme.primary.withValues(alpha: 0.35)
                ..strokeWidth = 2);
        }
        final lift = _text('lift', 12, scheme.primary.withValues(alpha: 0.8), AppType.heavy, letterSpacing: 1);
        lift.paint(canvas, Offset(rect.left + 12, liftY - lift.height - 3));
      }
      final land = _text('land', 12, scheme.primary, AppType.heavy, letterSpacing: 1);
      land.paint(canvas, Offset(rect.left + 12, nowY - land.height - 6));
    }

    // Steps scroll under the header: clip them to the body.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, headerH, size.width, size.height));
    final visible = <(int, PresetStep, double)>[];
    final next = <Role, int>{};
    final steps = c.preset.steps;
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final dBeat = s.beat - nowBeat;
      if (s.stepClass == StepClass.none || dBeat < -behind - 0.5 || dBeat > ahead + 0.5) continue;
      visible.add((i, s, dBeat));
      if (dBeat > -0.25 && c.verdicts[i] == null) next.putIfAbsent(s.foot, () => i);
    }

    // 3. Captions, above upcoming steps only (they never cross the now line).
    final scaler = textScaler.clamp(maxScaleFactor: 1.6);
    final captionSize = scaler.scale((r * 0.42).clamp(13.0, 28.0));
    for (final (i, s, dBeat) in visible) {
      if (dBeat <= 0.15) continue;
      final cx = laneX(s.foot) + laneW / 2;
      final cy = nowY - dBeat * pxPerBeat;
      final scale = next[s.foot] == i ? 1.15 : 1.0;
      final tp = _text(stepLabel(s.stepClass, s.foot), captionSize, scheme.onSurfaceVariant, AppType.strong,
          outline: scheme.surfaceContainerLow);
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - r * scale - 6 - tp.height));
    }

    // 4. Footprints, opaque so nothing strikes through them.
    for (final (i, s, dBeat) in visible) {
      final cx = laneX(s.foot) + laneW / 2;
      final cy = nowY - dBeat * pxPerBeat;
      final v = c.verdicts[i];
      final isNext = next[s.foot] == i;
      final rr = isNext ? r * 1.15 : r;
      final Color fill;
      if (v != null && v != Verdict.unjudged) {
        fill = v.fill;
      } else if (dBeat < -0.25) {
        fill = Color.lerp(scheme.primary, scheme.surface, 0.6)!; // passed, no verdict yet
      } else {
        fill = scheme.primary;
      }
      if (isNext) {
        canvas.drawCircle(Offset(cx, cy), rr + 9, Paint()..color = scheme.primary.withValues(alpha: 0.18));
      }
      canvas.drawCircle(Offset(cx, cy), rr, Paint()..color = fill);
      if (isNext) {
        canvas.drawCircle(
            Offset(cx, cy),
            rr - 2,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = onColor(fill).withValues(alpha: 0.7));
      }
      final icon = stepIcon(s.stepClass, s.foot);
      if (icon != null) _icon(canvas, icon, Offset(cx, cy), rr * 1.25, onColor(fill));
    }
    canvas.restore();

    // 5. The now line, on top: a soft glow and a solid primary line.
    for (final (_, rect) in lanes) {
      final a = Offset(rect.left + 10, nowY), b = Offset(rect.right - 10, nowY);
      canvas.drawLine(
          a,
          b,
          Paint()
            ..color = scheme.primary.withValues(alpha: 0.22)
            ..strokeWidth = 18
            ..strokeCap = StrokeCap.round);
      canvas.drawLine(
          a,
          b,
          Paint()
            ..color = scheme.primary
            ..strokeWidth = 6
            ..strokeCap = StrokeCap.round);
    }

    // 6. Pop labels: what the last verdict in each lane was, big.
    final popSize = min(scaler.scale((laneW * 0.11).clamp(22.0, 52.0)), laneW * 0.16);
    for (final h in c._hits) {
      final t = (nowMs - h.atMs) / StepChartController.popMs;
      if (t > 1) continue;
      // Pop in (overshoot) over the first 15%, fade over the last 30%.
      final grow = Curves.easeOutBack.transform((t / 0.15).clamp(0.0, 1.0));
      final scale = 0.6 + 0.4 * grow;
      final alpha = t < 0.7 ? 1.0 : 1 - (t - 0.7) / 0.3;
      final rect = lanes[h.foot.index].$2;
      final centre = Offset(rect.center.dx, min(nowY + behind * pxPerBeat * 0.5, size.height - popSize));
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.scale(scale);
      // A cue sits on the theme's primary (light in dark mode): its own on-colour.
      final tp = h.label == null
          ? null
          : _text(h.label!, popSize, h.verdict == null ? _scheme.onPrimary : Colors.white, AppType.heavy);
      final pill =
          tp == null ? Size(popSize * 1.9, popSize * 1.5) : Size(tp.width + popSize * 1.1, tp.height + popSize * 0.35);
      final pillRect = Rect.fromCenter(center: Offset.zero, width: pill.width, height: pill.height);
      // The fade is one layer alpha, so the cached text painters keep one colour.
      if (alpha < 1) canvas.saveLayer(pillRect.inflate(16), Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      canvas.drawRRect(
          RRect.fromRectAndRadius(pillRect.shift(const Offset(0, 4)), Radius.circular(pill.height / 2)),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.18)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      // A white rim sets the pill apart from the same-coloured step under it.
      canvas.drawRRect(RRect.fromRectAndRadius(pillRect.inflate(4), Radius.circular(pill.height / 2 + 4)),
          Paint()..color = Colors.white);
      canvas.drawRRect(
          RRect.fromRectAndRadius(pillRect, Radius.circular(pill.height / 2)), Paint()..color = _hitColor(h));
      if (tp == null) {
        _icon(canvas, Icons.check_rounded, Offset.zero, popSize * 1.3, Colors.white);
      } else {
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      }
      if (alpha < 1) canvas.restore();
      canvas.restore();
    }

    // 7. Header: lane names on an opaque band, so steps scroll under it.
    for (final (f, rect) in lanes) {
      final head = Rect.fromLTWH(rect.left, 0, rect.width, headerH);
      canvas.drawRRect(
          RRect.fromRectAndCorners(head,
              topLeft: const Radius.circular(Radii.lg), topRight: const Radius.circular(Radii.lg)),
          Paint()..color = scheme.surfaceContainerHigh);
      final tp =
          _text(f == Role.left ? 'left' : 'right', headerH * 0.4, scheme.onSurface, AppType.heavy, letterSpacing: 1);
      tp.paint(canvas, Offset(head.center.dx - tp.width / 2, head.center.dy - tp.height / 2));
    }
    canvas.restore();
  }

  Color _hitColor(_Hit h) => h.verdict?.fill ?? _scheme.primary;

  /// Laid-out text painters by what they draw: the same captions, labels and
  /// icons come back every frame. Cleared (and disposed) when it grows past
  /// [_cacheMax], e.g. after a resize changed every size.
  static final _cache = <(String, double, int, int, int?, double, String?, String?), TextPainter>{};
  static const _cacheMax = 160;

  static TextPainter _cached(
      (String, double, int, int, int?, double, String?, String?) key, TextPainter Function() make) {
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length >= _cacheMax) {
      for (final tp in _cache.values) {
        tp.dispose();
      }
      _cache.clear();
    }
    return _cache[key] = make();
  }

  static TextPainter _text(String s, double size, Color color, FontWeight weight,
          {Color? outline, double letterSpacing = 0}) =>
      _cached((s, size, color.toARGB32(), weight.value, outline?.toARGB32(), letterSpacing, null, null),
          () => _layoutText(s, size, color, weight, outline: outline, letterSpacing: letterSpacing));

  static TextPainter _layoutText(String s, double size, Color color, FontWeight weight,
      {Color? outline, double letterSpacing = 0}) {
    final style =
        TextStyle(fontSize: size, fontWeight: weight, color: color, letterSpacing: letterSpacing, height: 1.1);
    return TextPainter(
      text: TextSpan(
        text: s,
        // A halo in the lane colour keeps a caption readable over grid lines.
        style: outline == null
            ? style
            : style.copyWith(shadows: [
                for (final o in const [Offset(2, 0), Offset(-2, 0), Offset(0, 2), Offset(0, -2)])
                  Shadow(color: outline, offset: o),
              ]),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  static void _icon(Canvas canvas, IconData icon, Offset centre, double size, Color color) {
    final glyph = String.fromCharCode(icon.codePoint);
    final tp = _cached(
        (glyph, size, color.toARGB32(), 0, null, 0, icon.fontFamily, icon.fontPackage),
        () => TextPainter(
              text: TextSpan(
                text: glyph,
                style: TextStyle(color: color, fontSize: size, fontFamily: icon.fontFamily, package: icon.fontPackage),
              ),
              textDirection: TextDirection.ltr,
            )..layout());
    tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_StepChartPainter old) =>
      old.c != c || old.ahead != ahead || old.behind != behind || old.theme != theme || old.textScaler != textScaler;
}
