import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import '../models/preset.dart';

/// Scrolling step chart: two lanes (L, R), upcoming steps scroll up toward a
/// "now" line. Runs on the phone and, unchanged, as the big-screen web build.
///
/// `nowBeat` is the current beat (1-based, fractional). `verdicts` maps a
/// step index in `preset.steps` to the node's verdict once it arrives.
class StepChart extends StatelessWidget {
  const StepChart({
    super.key,
    required this.preset,
    required this.nowBeat,
    required this.verdicts,
    this.beatsVisibleAhead = 4,
    this.beatsVisibleBehind = 1.5,
  });

  final Preset preset;
  final double nowBeat;
  final Map<int, Verdict> verdicts;
  final double beatsVisibleAhead;
  final double beatsVisibleBehind;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StepChartPainter(
        preset: preset,
        nowBeat: nowBeat,
        verdicts: verdicts,
        ahead: beatsVisibleAhead,
        behind: beatsVisibleBehind,
        theme: Theme.of(context),
      ),
      size: Size.infinite,
    );
  }
}

class _StepChartPainter extends CustomPainter {
  _StepChartPainter({
    required this.preset,
    required this.nowBeat,
    required this.verdicts,
    required this.ahead,
    required this.behind,
    required this.theme,
  });

  final Preset preset;
  final double nowBeat;
  final Map<int, Verdict> verdicts;
  final double ahead, behind;
  final ThemeData theme;

  static const _arrow = {
    StepClass.forward: '↑',
    StepClass.back: '↓',
    StepClass.sideOut: '↔',
    StepClass.cross: '✕',
    StepClass.kick: '⇑',
    StepClass.inPlace: '•',
    StepClass.none: '',
  };

  Color _color(Verdict? v) => switch (v) {
        null || Verdict.unjudged => theme.colorScheme.primary,
        Verdict.correct => Colors.green,
        _ => Colors.red,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final laneW = size.width / 2;
    final pxPerBeat = size.height / (ahead + behind);
    final nowY = size.height - behind * pxPerBeat;

    // Lanes and beat grid.
    final grid = Paint()
      ..color = theme.dividerColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(laneW, 0), Offset(laneW, size.height), grid);
    final firstGridBeat = (nowBeat - behind).ceil();
    for (var b = firstGridBeat; b <= nowBeat + ahead; b++) {
      final y = nowY - (b - nowBeat) * pxPerBeat;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Now line.
    canvas.drawLine(
      Offset(0, nowY),
      Offset(size.width, nowY),
      Paint()
        ..color = theme.colorScheme.onSurface
        ..strokeWidth = 3,
    );

    // Footprints.
    final r = pxPerBeat * 0.3;
    for (var i = 0; i < preset.steps.length; i++) {
      final s = preset.steps[i];
      final dBeat = s.beat - nowBeat;
      if (dBeat < -behind || dBeat > ahead) continue;
      final cx = (s.foot == Role.left ? 0.5 : 1.5) * laneW;
      final cy = nowY - dBeat * pxPerBeat;
      final v = verdicts[i];
      final fill = Paint()..color = _color(v).withValues(alpha: dBeat < 0 && v == null ? 0.3 : 0.9);
      canvas.drawCircle(Offset(cx, cy), r, fill);

      final tp = TextPainter(
        text: TextSpan(
          text: _arrow[s.stepClass],
          style: TextStyle(color: Colors.white, fontSize: r * 1.2, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
    }

    // Lane labels.
    for (final (label, x) in [('L', laneW * 0.5), ('R', laneW * 1.5)]) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: theme.textTheme.headlineSmall),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, 8));
    }
  }

  @override
  bool shouldRepaint(_StepChartPainter old) =>
      old.nowBeat != nowBeat || old.verdicts != verdicts || old.preset != preset;
}
