import 'dart:math';
import 'dart:ui' show Offset, Rect;

import '../ble/protocol.dart';
import '../models/preset.dart';

/// Where each foot stands on the floor over a routine, worked out from the
/// step classes alone (not from the sensors): a static reference for the
/// floor map. Metres, seen from behind the dancer: +x is the dancer's right,
/// +y is forward. Out/in are relative to the midline, as in the step classes.
class FloorPlan {
  FloorPlan(this.preset) {
    final pos = {Role.left: const Offset(-gap / 2, 0), Role.right: const Offset(gap / 2, 0)};
    start = Map.of(pos);
    final lastBeat = {Role.left: double.negativeInfinity, Role.right: double.negativeInfinity};
    for (final i in preset.beatOrder) {
      final s = preset.steps[i];
      final from = pos[s.foot]!;
      final to = landing(s.stepClass, s.foot, from, pos[_other(s.foot)]!);
      // The swing ends on the beat; it starts up to 0.6 beat before, never
      // before the same foot's previous landing.
      final room = s.beat - lastBeat[s.foot]!;
      final dur = min(0.6, max(0.25, room * 0.75));
      final m = FloorMove(i, s.foot, s.stepClass, s.beat, dur, from, to);
      moves.add(m);
      _byFoot[s.foot]!.add(m);
      pos[s.foot] = to;
      lastBeat[s.foot] = s.beat;
    }
  }

  final Preset preset;
  late final Map<Role, Offset> start;
  final moves = <FloorMove>[];
  final _byFoot = {Role.left: <FloorMove>[], Role.right: <FloorMove>[]};

  /// Centre-to-centre distance of the feet side by side, a step's length, a side step.
  static const gap = 0.26, stride = 0.36, side = 0.32;

  /// How far a cross lands past the other foot, and in front of or behind it.
  static const crossPast = 0.10, crossDepth = 0.20;

  static Role _other(Role f) => f == Role.left ? Role.right : Role.left;

  /// Where a step of [cls] by [foot] from [from] lands, the other foot at [other].
  static Offset landing(StepClass cls, Role foot, Offset from, Offset other) {
    final o = foot == Role.left ? -1.0 : 1.0; // outward along x
    final beside = other.dx + o * gap; // closed up beside the other foot
    return switch (cls) {
      StepClass.forward => from.translate(0, stride),
      StepClass.back => from.translate(0, -stride),
      StepClass.sideOut => from.translate(o * side, 0),
      StepClass.sideIn => Offset(beside, other.dy),
      StepClass.forwardOut => from.translate(o * side, stride),
      StepClass.backOut => from.translate(o * side, -stride),
      StepClass.forwardIn => Offset(beside, from.dy + stride),
      StepClass.backIn => Offset(beside, from.dy - stride),
      StepClass.cross => Offset(other.dx - o * crossPast, other.dy + crossDepth),
      StepClass.crossBehind => Offset(other.dx - o * crossPast, other.dy - crossDepth),
      StepClass.inPlace || StepClass.kick || StepClass.none => from,
    };
  }

  /// One foot at [beat]: where it is, how high (0..1) and the move it is in.
  FootPose foot(Role f, double beat) {
    final list = _byFoot[f]!;
    // Last move starting at or before beat (binary search on landing beat).
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].beat - list[mid].dur <= beat) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return FootPose(start[f]!, 0, null, null);
    final m = list[lo - 1];
    final t = (beat - (m.beat - m.dur)) / m.dur;
    if (t >= 1) return FootPose(m.to, 0, null, m);
    final e = _ease(t);
    var p = Offset.lerp(m.from, m.to, e)!;
    var lift = sin(pi * t);
    if (m.cls == StepClass.kick) {
      p = p.translate(0, 0.30 * sin(pi * t));
      lift = 1.6 * lift;
    } else if (m.cls == StepClass.inPlace) {
      lift *= 0.55;
    } else if (m.cls == StepClass.crossBehind || m.cls == StepClass.cross) {
      // Swing round the standing foot rather than through it.
      final d = m.cls == StepClass.cross ? 1.0 : -1.0;
      p = p.translate(0, d * 0.12 * sin(pi * t));
    }
    return FootPose(p, lift, m, lo >= 2 ? list[lo - 2] : null, progress: t);
  }

  /// The floor the routine covers: every spot a foot lands on (metres).
  late final Rect extent = () {
    var r = Rect.fromPoints(start[Role.left]!, start[Role.right]!);
    for (final m in moves) {
      r = r.expandToInclude(Rect.fromCircle(center: m.to, radius: 0.001));
    }
    return r;
  }();

  /// The next [n] moves landing after [beat], in order.
  List<FloorMove> upcoming(double beat, int n) {
    var lo = 0, hi = moves.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (moves[mid].beat <= beat) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return moves.sublist(lo, min(moves.length, lo + n));
  }

  /// Moves that landed in the last [within] beats (for landing ripples).
  Iterable<FloorMove> landedWithin(double beat, double within) =>
      moves.where((m) => m.beat <= beat && beat - m.beat < within);

  /// Beats in one repetition of the pattern: the shortest whole number of bars
  /// after which the steps repeat. The whole routine if it never does.
  double get loopBeats {
    final steps = [for (final i in preset.beatOrder) preset.steps[i]];
    final bpb = preset.beatsPerBar.toDouble();
    for (var len = bpb; len < preset.lastBeat; len += bpb) {
      final first = steps.where((s) => s.beat < len + 1).toList();
      if (first.isEmpty || first.length >= steps.length) continue;
      var same = true;
      for (var k = 0; k < first.length && k + first.length < steps.length && same; k++) {
        final a = steps[k], b = steps[k + first.length];
        same = (b.beat - a.beat - len).abs() < 1e-6 && a.foot == b.foot && a.stepClass == b.stepClass;
      }
      if (same) return len;
    }
    return (preset.lastBeat / bpb).ceil() * bpb;
  }

  static double _ease(double t) => t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;
}

class FloorMove {
  const FloorMove(this.index, this.foot, this.cls, this.beat, this.dur, this.from, this.to);
  final int index; // into Preset.steps
  final Role foot;
  final StepClass cls;
  final double beat; // landing
  final double dur; // swing length in beats
  final Offset from, to;
}

class FootPose {
  const FootPose(this.pos, this.lift, this.move, this.previous, {this.progress = 1});
  final Offset pos;
  final double lift; // 0 planted .. ~1 top of the swing
  final FloorMove? move; // the move in progress or last landed
  final FloorMove? previous;
  final double progress; // through [move], 1 once landed
  bool get swinging => progress < 1 && move != null;
}
