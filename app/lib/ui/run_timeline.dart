import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import '../models/preset.dart';
import '../models/session_score.dart';
import 'style.dart';

/// Bars that need work: the wrong-step red, toned down.
const _weak = Color(0xFFE5776B);

/// One scheduled step as the run went: its verdict and how early (−) or late
/// (+) it landed, when the node timed it.
typedef TimelineStep = ({double beat, Role foot, Verdict verdict, int? timingMs});

/// The run over time, worked out from a [SessionScore]: every step, the
/// share of correct steps per bar and over a rolling two-bar window, the
/// weakest bars, and the rewinds per bar in Practice.
class RunTimelineData {
  RunTimelineData(this.preset, SessionScore score, {bool practice = false})
      : bars = max(1, preset.bars),
        rewinds = Map.of(score.rewindsByBar) {
    for (var i = 0; i < preset.steps.length; i++) {
      final e = score.latest[i];
      if (e == null) continue; // not reached (the run ended early)
      // Practice is scored on the first try; the timing is the latest one's.
      final v = practice ? (score.firstTry[i] ?? e.verdict) : e.verdict;
      if (v == Verdict.unjudged) continue;
      final s = preset.steps[i];
      final timed = e.verdict == Verdict.correct || e.verdict == Verdict.offBeat || e.verdict == Verdict.wrongStep;
      steps.add((beat: s.beat, foot: s.foot, verdict: v, timingMs: timed ? e.timingErrMs : null));
    }
    for (final s in steps) {
      final b = barOf(s.beat, preset.beatsPerBar);
      _judged[b] = (_judged[b] ?? 0) + 1;
      if (s.verdict == Verdict.correct) _correct[b] = (_correct[b] ?? 0) + 1;
    }
  }

  final Preset preset;
  final int bars;
  final steps = <TimelineStep>[];
  final Map<int, int> rewinds;
  final _judged = <int, int>{}, _correct = <int, int>{};

  int get beatsPerBar => preset.beatsPerBar;
  bool get isEmpty => steps.isEmpty;

  int judgedIn(int bar) => _judged[bar] ?? 0;
  int correctIn(int bar) => _correct[bar] ?? 0;

  /// Share correct in [bar], or null with nothing judged there.
  double? accuracyIn(int bar) => judgedIn(bar) == 0 ? null : correctIn(bar) / judgedIn(bar);

  /// Share correct over [bar] and the bar before it: the line on the chart,
  /// steadier than bar by bar.
  double? rollingAccuracy(int bar) {
    final n = judgedIn(bar) + judgedIn(bar - 1);
    return n == 0 ? null : (correctIn(bar) + correctIn(bar - 1)) / n;
  }

  /// Up to three bars worth practicing: under 70 % correct with at least two
  /// steps judged, worst first (ties: the earlier bar).
  List<int> get weakBars {
    final weak = [
      for (var b = 1; b <= bars; b++)
        if (judgedIn(b) >= 2 && accuracyIn(b)! < 0.7) b
    ]..sort((a, b) {
        final c = accuracyIn(a)!.compareTo(accuracyIn(b)!);
        return c != 0 ? c : a.compareTo(b);
      });
    return weak.take(3).toList();
  }

  /// The first beat of [bar].
  double barStartBeat(int bar) => (bar - 1) * beatsPerBar + 1.0;

  /// Steps in [bar] that landed late or early by more than the on-beat window.
  ({int late, int early}) offBeatIn(int bar) {
    var late = 0, early = 0;
    for (final s in steps) {
      if (barOf(s.beat, beatsPerBar) != bar || s.verdict != Verdict.offBeat) continue;
      if ((s.timingMs ?? 0) > 0) {
        late++;
      } else {
        early++;
      }
    }
    return (late: late, early: early);
  }
}

/// The summary's timeline: accuracy over the run as a line, and below it a
/// lane per foot with a dot for every step in its verdict's colour, higher
/// for late and lower for early. The weakest bars are marked; tap any bar to
/// see it, and practice from there with [onPractice].
class RunTimeline extends StatefulWidget {
  const RunTimeline({super.key, required this.data, required this.onPractice, this.height = 260});
  final RunTimelineData data;

  /// Starts Practice from this beat (the first beat of the chosen bar).
  final ValueChanged<double> onPractice;
  final double height;

  /// Steps within this many ms of the beat are on it (the node's window).
  static const onBeatMs = 150;

  /// The timing lanes run from this early to this late.
  static const rangeMs = 300;

  /// The chart itself (for tests).
  static const chartKey = ValueKey('run-timeline-chart');

  @override
  State<RunTimeline> createState() => _RunTimelineState();
}

class _RunTimelineState extends State<RunTimeline> {
  /// The bar shown under the chart: the weakest one to begin with.
  late int? _bar = widget.data.weakBars.firstOrNull;

  RunTimelineData get d => widget.data;

  void _tap(Offset p, Size size) {
    final g = _Geometry(size, d);
    if (p.dx < g.left || p.dx > g.right) return;
    final bar = ((p.dx - g.left) / g.width * d.bars).floor() + 1;
    setState(() => _bar = bar.clamp(1, d.bars));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weak = d.weakBars;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: _describe(),
          child: LayoutBuilder(builder: (context, c) {
            final size = Size(c.maxWidth, widget.height);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (t) => _tap(t.localPosition, size),
              child: CustomPaint(
                key: RunTimeline.chartKey,
                size: size,
                painter: _TimelinePainter(d, selected: _bar, weak: weak, text: theme.textTheme),
              ),
            );
          }),
        ),
        const SizedBox(height: Space.sm),
        _legend(theme),
        const SizedBox(height: Space.md),
        _barRow(theme),
      ],
    );
  }

  String _describe() {
    final weak = d.weakBars;
    final pct = [
      for (var b = 1; b <= d.bars; b++)
        if (d.accuracyIn(b) case final a?) 'bar $b ${(a * 100).round()}%'
    ];
    return 'Accuracy over the run: ${pct.join(', ')}. '
        '${weak.isEmpty ? 'No weak bars.' : 'Weakest: bar ${weak.join(', bar ')}.'}';
  }

  Widget _legend(ThemeData theme) {
    final small = theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget dot(Color c, String label, {bool hollow = false}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hollow ? null : c,
                border: hollow ? Border.all(color: c, width: 2) : null,
              ),
            ),
            const SizedBox(width: Space.xs),
            Text(label, style: small),
          ],
        );
    return Wrap(
      spacing: Space.md,
      runSpacing: Space.xs,
      children: [
        dot(Verdict.correct.fill, 'correct'),
        dot(Verdict.wrongStep.fill, 'wrong step'),
        dot(Verdict.offBeat.fill, 'off beat'),
        dot(Verdict.missed.inkFor(Brightness.dark), 'missed', hollow: true),
        if (d.rewinds.values.any((n) => n > 0)) dot(Stage.tape, 'rewinds (number over the bar)'),
        Text('Higher dot = later. Tap a bar for details.', style: small),
      ],
    );
  }

  /// The chosen bar in words, with a button to practice from it.
  Widget _barRow(ThemeData theme) {
    final b = _bar;
    if (b == null) {
      return Text('No weak bars: every bar was at least 70% correct.',
          style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    }
    final n = d.judgedIn(b), ok = d.correctIn(b);
    final off = d.offBeatIn(b);
    final tries = d.rewinds[b];
    final details = [
      if (n == 0) 'not danced' else '$ok of $n correct',
      if (off.late > 0) '${off.late} late',
      if (off.early > 0) '${off.early} early',
      if (tries != null && tries > 0) '$tries ${tries == 1 ? 'rewind' : 'rewinds'}',
    ];
    final weak = d.weakBars.contains(b);
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, Space.sm),
      decoration: BoxDecoration(
        color: (weak ? _weak : Stage.tape).withValues(alpha: 0.12),
        borderRadius: Radii.mdAll,
        border: Border.all(color: (weak ? _weak : Stage.tape).withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Bar $b${weak ? ' · needs work' : ''}', style: theme.textTheme.titleMedium),
                Text(details.join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          FilledButton.tonalIcon(
            onPressed: () => widget.onPractice(d.barStartBeat(b)),
            icon: const Icon(Icons.replay_rounded),
            label: Text(MediaQuery.sizeOf(context).width < 430 ? 'Practice' : 'Practice from here'),
          ),
        ],
      ),
    );
  }
}

/// Where things go: the accuracy chart on top, the two foot lanes under it,
/// bar numbers along the bottom.
class _Geometry {
  _Geometry(this.size, RunTimelineData d)
      : left = 44,
        right = size.width - 8,
        accTop = 18,
        accH = size.height * 0.30 {
    laneTop = accTop + accH + 18;
    laneH = (size.height - laneTop - axisH - 6) / 2;
    beats = d.bars * d.beatsPerBar.toDouble();
  }

  final Size size;
  final double left, right, accTop, accH;
  late final double laneTop, laneH, beats;
  static const axisH = 22.0;

  double get width => right - left;
  double x(double beat) => left + (beat - 1) / beats * width;
  double accY(double a) => accTop + accH * (1 - a);
  double laneMid(Role foot) => laneTop + laneH * (foot == Role.left ? 0.5 : 1.5);

  /// Late is up: [ms] clamped to the lanes' range.
  double timingY(Role foot, int ms) =>
      laneMid(foot) - ms.clamp(-RunTimeline.rangeMs, RunTimeline.rangeMs) / RunTimeline.rangeMs * laneH * 0.46;
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.d, {required this.selected, required this.weak, required this.text});
  final RunTimelineData d;
  final int? selected;
  final List<int> weak;
  final TextTheme text;

  static const _feet = {Role.left: Stage.pink, Role.right: Stage.blue};

  @override
  void paint(Canvas canvas, Size size) {
    final g = _Geometry(size, d);
    final bpb = d.beatsPerBar;
    final barW = g.width / d.bars;
    final bottom = size.height - _Geometry.axisH;

    // Bars: the weak ones tinted, the chosen one lit.
    for (var b = 1; b <= d.bars; b++) {
      final r = Rect.fromLTRB(g.x(d.barStartBeat(b)), 0, g.x(d.barStartBeat(b) + bpb), bottom);
      if (b == selected) {
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(1), const Radius.circular(8)),
            Paint()..color = (weak.contains(b) ? _weak : Stage.tape).withValues(alpha: 0.2));
        canvas.drawRRect(
            RRect.fromRectAndRadius(r.deflate(1), const Radius.circular(8)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = (weak.contains(b) ? _weak : Stage.tape).withValues(alpha: 0.8));
      } else if (weak.contains(b)) {
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(1), const Radius.circular(8)),
            Paint()..color = _weak.withValues(alpha: 0.1));
      }
    }

    final grid = Paint()
      ..color = Stage.line
      ..strokeWidth = 1;
    // Bar lines.
    for (var b = 0; b <= d.bars; b++) {
      final x = g.x(b * bpb + 1.0);
      canvas.drawLine(Offset(x, g.laneTop), Offset(x, bottom), grid);
    }

    // Accuracy chart: 50 % and 100 % guides, then the rolling line.
    for (final a in [0.5, 1.0]) {
      canvas.drawLine(Offset(g.left, g.accY(a)), Offset(g.right, g.accY(a)), grid);
      _label(canvas, '${(a * 100).round()}%', Offset(g.left - 6, g.accY(a)), align: 1);
    }
    canvas.drawLine(
        Offset(g.left, g.accY(0)), Offset(g.right, g.accY(0)), grid..color = Stage.line.withValues(alpha: 0.6));
    final runs = <List<Offset>>[[]];
    for (var b = 1; b <= d.bars; b++) {
      final a = d.rollingAccuracy(b);
      if (a == null) {
        if (runs.last.isNotEmpty) runs.add([]);
        continue;
      }
      runs.last.add(Offset(g.x(d.barStartBeat(b) + bpb / 2), g.accY(a)));
    }
    for (final pts in runs.where((r) => r.isNotEmpty)) {
      final line = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        line.lineTo(p.dx, p.dy);
      }
      final area = Path.from(line)
        ..lineTo(pts.last.dx, g.accY(0))
        ..lineTo(pts.first.dx, g.accY(0))
        ..close();
      canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Stage.tape.withValues(alpha: 0.35), Stage.tape.withValues(alpha: 0.02)],
            ).createShader(Rect.fromLTRB(g.left, g.accTop, g.right, g.accY(0))));
      canvas.drawPath(
          line,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round
            ..color = Stage.tape);
      for (final p in pts) {
        canvas.drawCircle(p, 3.5, Paint()..color = Stage.tape);
      }
    }

    // Practice: how many times each bar was rewound, over the chart.
    for (final e in d.rewinds.entries) {
      if (e.value <= 0 || e.key < 1 || e.key > d.bars) continue;
      final c = Offset(g.x(d.barStartBeat(e.key) + bpb / 2), 9);
      canvas.drawCircle(c, 8, Paint()..color = Stage.tape);
      _label(canvas, '${e.value}', c, align: 0, color: Stage.night, size: 11, bold: true);
    }

    // Foot lanes: the on-beat band, the beat line, then a dot per step.
    for (final foot in Role.values) {
      final mid = g.laneMid(foot);
      final band = RunTimeline.onBeatMs / RunTimeline.rangeMs * g.laneH * 0.46;
      canvas.drawRect(Rect.fromLTRB(g.left, mid - band, g.right, mid + band),
          Paint()..color = Verdict.correct.fill.withValues(alpha: 0.1));
      canvas.drawLine(
          Offset(g.left, mid),
          Offset(g.right, mid),
          Paint()
            ..color = Stage.line
            ..strokeWidth = 1.5);
      _label(canvas, foot == Role.left ? 'L' : 'R', Offset(g.left - 14, mid),
          align: 0, color: _feet[foot]!, bold: true);
    }
    final r = max(3.5, min(6.5, barW / bpb * 0.32));
    for (final s in d.steps) {
      final x = g.x(s.beat + 0.5);
      if (s.verdict == Verdict.missed) {
        canvas.drawCircle(
            Offset(x, g.laneMid(s.foot)),
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = Verdict.missed.inkFor(Brightness.dark));
        continue;
      }
      final y = g.timingY(s.foot, s.timingMs ?? 0);
      canvas.drawCircle(Offset(x, y), r + 2, Paint()..color = s.verdict.fill.withValues(alpha: 0.25));
      canvas.drawCircle(Offset(x, y), r, Paint()..color = s.verdict.fill);
    }

    // Bar numbers, as many as fit.
    final every = [1, 2, 4, 8].firstWhere((n) => barW * n >= 26, orElse: () => 8);
    for (var b = 1; b <= d.bars; b++) {
      if (b != 1 && b % every != 0 && b != selected) continue;
      _label(canvas, '$b', Offset(g.x(d.barStartBeat(b) + bpb / 2), bottom + 11),
          align: 0, color: b == selected ? Colors.white : null, bold: b == selected);
    }
  }

  /// Small text centred vertically on [at]; [align] -1 left, 0 centre, 1 right of it.
  void _label(Canvas canvas, String s, Offset at, {int align = -1, Color? color, double size = 12, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: AppType.family,
          fontSize: size,
          fontWeight: bold ? AppType.heavy : AppType.strong,
          color: color ?? text.bodySmall?.color?.withValues(alpha: 0.75) ?? Colors.white70,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) { 1 => -tp.width, 0 => -tp.width / 2, _ => 0.0 };
    tp.paint(canvas, at + Offset(dx, -tp.height / 2));
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => old.d != d || old.selected != selected;
}
