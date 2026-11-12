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

/// Mistakes for one foot and step class, with a count per kind of mistake.
typedef MistakeGroup = ({
  Role foot,
  StepClass step,
  int count,
  Map<Verdict, int> byVerdict,

  /// Index into [Preset.steps] of the first step in the group.
  int first,
});

/// Bar numbers are 1-based; beat 1 is the first beat of bar 1.
int barOf(double beat) => (beat - 1) ~/ 4 + 1;

/// Scores a session from the nodes' step events: one result per scheduled
/// step, where a later verdict for a step replaces an earlier one (a practice
/// retry, or a node that reports missed and then correct).
///
/// Events are placed in beats after beat 1 of the routine, so the score does
/// not depend on the tempo (Practice can slow down mid-session) and the
/// caller owns the clock maths (node offset, t0).
class SessionScore {
  SessionScore(this.preset);

  final Preset preset;

  /// Latest event per step index into [Preset.steps].
  final latest = <int, StepEvent>{};

  /// The verdict each step got on its first attempt: before any rewind or
  /// restart replayed it.
  final firstTry = <int, Verdict>{};
  final _replayed = <int>{};

  /// What the chart shows: verdicts from the current attempt only, so steps a
  /// rewind is about to replay go back to pending.
  final shown = <int, Verdict>{};

  int extras = 0;

  /// Practice rewinds to each bar.
  final rewindsByBar = <int, int>{};
  int get rewinds => rewindsByBar.values.fold(0, (a, b) => a + b);

  /// Steps before this beat are not being judged in the current segment.
  double fromBeat = 1;

  final _lastSeq = <Role, int>{};

  /// A new segment begins (nodes restarted). Seq counters restart on the
  /// nodes, and steps from [fromBeat] on are pending again on the chart.
  void restart({double fromBeat = 1}) {
    this.fromBeat = fromBeat;
    _lastSeq.clear();
    _replayed.addAll(latest.keys.where((i) => preset.steps[i].beat >= fromBeat));
    shown.removeWhere((i, _) => preset.steps[i].beat >= fromBeat);
  }

  /// Rewind to [beat] (a bar start): same as [restart], counted as a retry of that bar.
  void rewind(double beat) {
    rewindsByBar.update(barOf(beat), (n) => n + 1, ifAbsent: () => 1);
    restart(fromBeat: beat);
  }

  /// A node came back (it may have rebooted): its seq counter starts over.
  void forgetSeq(Role foot) => _lastSeq.remove(foot);

  int count(Verdict v) => latest.values.where((e) => e.verdict == v).length;

  /// Steps with a verdict (correct or a mistake).
  int get judged => latest.values.where((e) => e.verdict != Verdict.unjudged).length;

  /// Share of judged steps that were correct, or null before any.
  double? get accuracy => judged == 0 ? null : count(Verdict.correct) / judged;

  /// Share of judged steps that were correct the first time they were danced.
  /// In Practice this is the honest number: [accuracy] counts the retries.
  double? get firstTryAccuracy {
    final judgedFirst = firstTry.values.where((v) => v != Verdict.unjudged);
    if (judgedFirst.isEmpty) return null;
    return judgedFirst.where((v) => v == Verdict.correct).length / judgedFirst.length;
  }

  /// The bar that took the most tries (rewinds + 1), or null with no rewinds.
  ({int bar, int tries})? get hardestBar {
    if (rewindsByBar.isEmpty) return null;
    final e = rewindsByBar.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key < a.key) ? b : a);
    return (bar: e.key, tries: e.value + 1);
  }

  /// Mean timing error over correct and off-beat steps, ms (+ = late).
  double? get meanTimingMs {
    final timed = latest.values.where((e) => e.verdict == Verdict.correct || e.verdict == Verdict.offBeat);
    if (timed.isEmpty) return null;
    return timed.map((e) => e.timingErrMs).reduce((a, b) => a + b) / timed.length;
  }

  /// Mistakes grouped by foot and scheduled step, worst first. Ties go to the
  /// group that came first in the routine, so the pick is stable.
  List<MistakeGroup> mistakesByStep() {
    final groups = <(Role, StepClass), MistakeGroup>{};
    final indices = latest.keys.toList()..sort();
    for (final i in indices) {
      final v = latest[i]!.verdict;
      if (v == Verdict.correct || v == Verdict.unjudged) continue;
      final s = preset.steps[i];
      final key = (s.foot, s.stepClass);
      final g = groups[key];
      groups[key] = (
        foot: s.foot,
        step: s.stepClass,
        count: (g?.count ?? 0) + 1,
        byVerdict: {...?g?.byVerdict, v: (g?.byVerdict[v] ?? 0) + 1},
        first: g?.first ?? i,
      );
    }
    return groups.values.toList()
      ..sort((a, b) {
        final c = b.count.compareTo(a.count);
        return c != 0 ? c : a.first.compareTo(b.first);
      });
  }

  /// Nearest scheduled step for [foot] in the current segment within 0.75 beat.
  int? stepAt(Role foot, double beat) {
    int? best;
    var bestErr = double.infinity;
    for (var i = 0; i < preset.steps.length; i++) {
      final s = preset.steps[i];
      if (s.foot != foot || s.beat < fromBeat) continue;
      final err = (s.beat - beat).abs();
      if (err < bestErr) {
        bestErr = err;
        best = i;
      }
    }
    return bestErr <= 0.75 ? best : null;
  }

  /// Scores one event from [foot] whose strike fell on [beat] (fractional).
  ScoredEvent add(Role foot, StepEvent e, double beat) {
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
    final i = stepAt(foot, beat);
    if (i == null) return (fate: EventFate.unmatched, step: null);
    latest[i] = e;
    shown[i] = e.verdict;
    if (!_replayed.contains(i)) firstTry[i] = e.verdict;
    return (fate: EventFate.step, step: i);
  }
}

/// What Practice does after a mistake.
enum PracticeAction {
  /// Note it and keep dancing.
  carryOn,

  /// Stop and go back to the start of the bar.
  rewind,

  /// This bar has failed [PracticeCoach.maxTries] times running: offer to slow
  /// down or move on, instead of looping on it.
  offerChoice,
}

/// Practice mode's rule for mistakes.
///
/// - A wrong or missed step rewinds to the start of its bar.
/// - An off-beat step does not: the step itself was right, and stopping for
///   timing alone made dancers loop on one bar. The chart still flashes it and
///   the summary counts it.
/// - After [maxTries] failed tries running on the same bar, the dancer is
///   offered "Slow down" (try again at a lower tempo, tries start over) or
///   "Keep going" (move past the bar; it is not rewound again).
class PracticeCoach {
  static const maxTries = 3;

  int? _bar;
  int _fails = 0;
  final _passedOver = <int>{};

  /// The bar being drilled and the try about to start on it (1-based).
  int? get bar => _bar;
  int get nextTry => _fails + 1;

  PracticeAction onMistake(Verdict v, double beat) {
    if (v != Verdict.wrongStep && v != Verdict.missed) return PracticeAction.carryOn;
    final bar = barOf(beat);
    if (_passedOver.contains(bar)) return PracticeAction.carryOn;
    if (bar != _bar) {
      _bar = bar;
      _fails = 0;
    }
    _fails++;
    return _fails >= maxTries ? PracticeAction.offerChoice : PracticeAction.rewind;
  }

  /// Slow down: the bar gets [maxTries] fresh tries at the new tempo.
  void slowDown() => _fails = 0;

  /// Keep going: move past the bar and do not rewind it again.
  void keepGoing() {
    if (_bar case final b?) _passedOver.add(b);
    _bar = null;
    _fails = 0;
  }
}
