import '../ble/protocol.dart';
import 'preset.dart';

/// What happened to one incoming step event.
enum EventFate {
  /// Same or older seq than one already seen from this node since the last start.
  duplicate,

  /// A strike with nothing scheduled (expected class none). Never a chart step.
  extra,

  /// Judged, but no scheduled step in the current segment is near it (for
  /// example a step before the bar a practice rewind restarted from).
  unmatched,

  /// Matched to a scheduled step; [ScoredEvent.step] says which.
  step,
}

typedef ScoredEvent = ({EventFate fate, int? step});

/// Scores a session from the nodes' step events: one result per scheduled
/// step, where a later verdict for a step replaces an earlier one (a practice
/// retry, or a node that reports missed and then correct).
///
/// Timing is given as ms after beat 1 of the current segment, so the caller
/// owns the clock maths (node offset, t0).
class SessionScore {
  SessionScore(this.preset);

  final Preset preset;

  /// Latest event per step index into [Preset.steps].
  final latest = <int, StepEvent>{};

  /// What the chart shows: verdicts from the current attempt only, so steps a
  /// rewind is about to replay go back to pending.
  final shown = <int, Verdict>{};

  int extras = 0;

  /// Practice rewinds so far.
  int rewinds = 0;

  /// Steps before this beat are not being judged in the current segment.
  double fromBeat = 1;

  final _lastSeq = <Role, int>{};

  /// A new segment begins (nodes restarted). Seq counters restart on the
  /// nodes, and steps from [fromBeat] on are pending again on the chart.
  void restart({double fromBeat = 1}) {
    this.fromBeat = fromBeat;
    _lastSeq.clear();
    shown.removeWhere((i, _) => preset.steps[i].beat >= fromBeat);
  }

  /// Rewind to [beat]: same as [restart], counted as a retry.
  void rewind(double beat) {
    rewinds++;
    restart(fromBeat: beat);
  }

  int count(Verdict v) => latest.values.where((e) => e.verdict == v).length;

  /// Steps with a verdict (correct or a mistake).
  int get judged => latest.values.where((e) => e.verdict != Verdict.unjudged).length;

  /// Share of judged steps that were correct, or null before any.
  double? get accuracy => judged == 0 ? null : count(Verdict.correct) / judged;

  /// Mean timing error over correct and off-beat steps, ms (+ = late).
  double? get meanTimingMs {
    final timed = latest.values.where((e) => e.verdict == Verdict.correct || e.verdict == Verdict.offBeat);
    if (timed.isEmpty) return null;
    return timed.map((e) => e.timingErrMs).reduce((a, b) => a + b) / timed.length;
  }

  /// Mistakes grouped by foot and scheduled step, worst first. Ties go to the
  /// group that came first in the routine, so the pick is stable.
  List<({Role foot, StepClass step, int count})> mistakesByStep() {
    final groups = <(Role, StepClass), ({int count, int first})>{};
    final indices = latest.keys.toList()..sort();
    for (final i in indices) {
      final v = latest[i]!.verdict;
      if (v == Verdict.correct || v == Verdict.unjudged) continue;
      final s = preset.steps[i];
      final g = groups[(s.foot, s.stepClass)];
      groups[(s.foot, s.stepClass)] = (count: (g?.count ?? 0) + 1, first: g?.first ?? i);
    }
    final sorted = groups.entries.toList()
      ..sort((a, b) {
        final c = b.value.count.compareTo(a.value.count);
        return c != 0 ? c : a.value.first.compareTo(b.value.first);
      });
    return [for (final e in sorted) (foot: e.key.$1, step: e.key.$2, count: e.value.count)];
  }

  /// Nearest scheduled step for [foot] in the current segment within 0.75 beat.
  int? stepAt(Role foot, double msAfterT0) {
    int? best;
    var bestErr = double.infinity;
    for (var i = 0; i < preset.steps.length; i++) {
      final s = preset.steps[i];
      if (s.foot != foot || s.beat < fromBeat) continue;
      final err = (preset.beatToMs(s.beat) - msAfterT0).abs();
      if (err < bestErr) {
        bestErr = err;
        best = i;
      }
    }
    return bestErr <= preset.beatMs * 0.75 ? best : null;
  }

  ScoredEvent add(Role foot, StepEvent e, double msAfterT0) {
    final last = _lastSeq[foot];
    // u16 counter: newer means 1..32767 ahead, modulo 2^16.
    if (last != null) {
      final ahead = (e.seq - last) & 0xffff;
      if (ahead == 0 || ahead >= 0x8000) return (fate: EventFate.duplicate, step: null);
    }
    _lastSeq[foot] = e.seq;

    if (e.verdict == Verdict.extra || e.expectedClass == StepClass.none) {
      extras++;
      return (fate: EventFate.extra, step: null);
    }
    final i = stepAt(foot, msAfterT0);
    if (i == null) return (fate: EventFate.unmatched, step: null);
    latest[i] = e;
    shown[i] = e.verdict;
    return (fate: EventFate.step, step: i);
  }
}
