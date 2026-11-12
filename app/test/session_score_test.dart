import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/models/session_score.dart';
import 'package:flutter_test/flutter_test.dart';

/// 120 bpm (500 ms a beat), two bars, alternating feet on every beat.
final preset = Preset(1, 'Test', 120, 4, [
  for (var b = 1; b <= 8; b++) PresetStep(b.toDouble(), b.isOdd ? Role.left : Role.right, StepClass.forward),
]);

StepEvent ev(int seq, Verdict v, {StepClass expected = StepClass.forward, int errMs = 0}) =>
    StepEvent(seq, 0, StepClass.forward, 200, expected, errMs, v);

/// Where an event lands, in beats (the score works in beats, not ms).
double at(double beat) => beat;

void main() {
  test('an event is matched to the nearest step of its foot', () {
    final s = SessionScore(preset);
    final r = s.add(Role.right, ev(0, Verdict.correct), at(4) + 0.2);
    expect(r.fate, EventFate.step);
    expect(r.step, 3); // beat 4, right foot
    expect(s.count(Verdict.correct), 1);
  });

  test('extras never land on a chart step or in the score', () {
    final s = SessionScore(preset);
    final r = s.add(Role.left, ev(0, Verdict.extra, expected: StepClass.none), at(1));
    expect(r.fate, EventFate.extra);
    expect(s.shown, isEmpty);
    expect(s.latest, isEmpty);
    expect(s.extras, 1);
    expect(s.judged, 0);
    expect(s.accuracy, isNull);
    expect(s.mistakesByStep(), isEmpty);
  });

  test('a later verdict for a step replaces the earlier one', () {
    final s = SessionScore(preset);
    s.add(Role.left, ev(0, Verdict.missed), at(1));
    s.add(Role.left, ev(1, Verdict.correct), at(1) + 0.1);
    expect(s.count(Verdict.missed), 0);
    expect(s.count(Verdict.correct), 1);
    expect(s.judged, 1);
    expect(s.shown[0], Verdict.correct);
  });

  test('duplicate and stale seqs are dropped, and seq restarts with the nodes', () {
    final s = SessionScore(preset);
    expect(s.add(Role.left, ev(5, Verdict.correct), at(1)).fate, EventFate.step);
    expect(s.add(Role.left, ev(5, Verdict.wrongStep), at(1)).fate, EventFate.duplicate);
    expect(s.add(Role.left, ev(4, Verdict.wrongStep), at(1)).fate, EventFate.duplicate);
    expect(s.count(Verdict.correct), 1);
    // The other foot has its own counter.
    expect(s.add(Role.right, ev(0, Verdict.correct), at(2)).fate, EventFate.step);
    // The nodes restart seq from 0 on every start.
    s.restart();
    expect(s.add(Role.left, ev(0, Verdict.correct), at(3)).fate, EventFate.step);
    // u16 wrap counts as newer.
    s.restart();
    expect(s.add(Role.left, ev(0xffff, Verdict.correct), at(5)).fate, EventFate.step);
    expect(s.add(Role.left, ev(0, Verdict.correct), at(7)).fate, EventFate.step);
  });

  test('after a rewind, steps before the restart bar are ignored and the replayed bar counts once', () {
    final s = SessionScore(preset);
    // Bar 2 (beats 5-8): correct on 5, mistake on 6.
    s.add(Role.left, ev(0, Verdict.correct), at(5));
    s.add(Role.right, ev(0, Verdict.wrongStep), at(6));
    s.rewind(5);
    expect(s.rewinds, 1);
    expect(s.fromBeat, 5);
    // The chart shows bar 2 as pending again; the score keeps the last results.
    expect(s.shown, isEmpty);
    expect(s.count(Verdict.wrongStep), 1);

    // A node reporting a step before the restart bar (count-in) is not scored.
    expect(s.add(Role.right, ev(0, Verdict.missed), at(4)).fate, EventFate.unmatched);
    expect(s.count(Verdict.missed), 0);

    // The replay: both correct now, and each step counts once.
    s.add(Role.left, ev(1, Verdict.correct), at(5));
    s.add(Role.right, ev(1, Verdict.correct), at(6));
    expect(s.count(Verdict.correct), 2);
    expect(s.count(Verdict.wrongStep), 0);
    expect(s.judged, 2);
  });

  test('mistake ranking is stable on ties: earliest in the routine first', () {
    final s = SessionScore(preset);
    s.add(Role.right, ev(0, Verdict.missed), at(2)); // right forward
    s.add(Role.left, ev(0, Verdict.offBeat, errMs: 200), at(3)); // left forward
    final m = s.mistakesByStep();
    expect(m.first.foot, Role.right);
    expect(m.map((g) => g.count), [1, 1]);
    expect(s.meanTimingMs, 200);
  });

  test('first-try accuracy keeps the first attempt; a replay only fixes the latest', () {
    final s = SessionScore(preset);
    // Bar 1: beat 1 right, beat 2 wrong. Rewind, then both right.
    s.add(Role.left, ev(0, Verdict.correct), at(1));
    s.add(Role.right, ev(0, Verdict.wrongStep), at(2));
    s.rewind(1);
    s.add(Role.left, ev(0, Verdict.correct), at(1));
    s.add(Role.right, ev(0, Verdict.correct), at(2));
    // Bar 2, first time: right; a node revising its own verdict in the same
    // attempt (missed, then correct) still counts as the first try.
    s.add(Role.left, ev(1, Verdict.missed), at(5));
    s.add(Role.left, ev(2, Verdict.correct), at(5) + 0.1);
    expect(s.accuracy, 1.0);
    expect(s.firstTry, {0: Verdict.correct, 1: Verdict.wrongStep, 4: Verdict.correct});
    expect(s.firstTryAccuracy, closeTo(2 / 3, 1e-9));
  });

  test('tries per bar and the hardest bar', () {
    final s = SessionScore(preset);
    expect(s.hardestBar, isNull);
    s.rewind(5);
    s.rewind(5);
    s.rewind(1);
    expect(s.rewindsByBar, {2: 2, 1: 1});
    expect(s.rewinds, 3);
    expect(s.hardestBar, (bar: 2, tries: 3));
    // Ties go to the earlier bar.
    s.rewind(1);
    expect(s.hardestBar, (bar: 1, tries: 3));
  });

  test('mistake groups break down by kind and remember the first step', () {
    final s = SessionScore(preset);
    s.add(Role.left, ev(0, Verdict.wrongStep), at(3));
    s.add(Role.left, ev(1, Verdict.missed), at(5));
    s.add(Role.left, ev(2, Verdict.missed), at(7));
    final g = s.mistakesByStep().single;
    expect(g.count, 3);
    expect(g.byVerdict, {Verdict.wrongStep: 1, Verdict.missed: 2});
    expect(g.first, 2);
  });

  test('a node that comes back restarts its seq without a segment restart', () {
    final s = SessionScore(preset);
    s.add(Role.left, ev(40, Verdict.correct), at(1));
    expect(s.add(Role.left, ev(0, Verdict.correct), at(3)).fate, EventFate.duplicate);
    s.forgetSeq(Role.left);
    expect(s.add(Role.left, ev(0, Verdict.correct), at(3)).fate, EventFate.step);
  });

  group('practice rule', () {
    test('off-beat carries on; wrong and missed rewind', () {
      final c = PracticeCoach();
      expect(c.onMistake(Verdict.offBeat, 2), PracticeAction.carryOn);
      expect(c.onMistake(Verdict.correct, 2), PracticeAction.carryOn);
      expect(c.onMistake(Verdict.wrongStep, 2), PracticeAction.rewind);
      expect(c.nextTry, 2);
      expect(c.onMistake(Verdict.missed, 3), PracticeAction.rewind);
      expect(c.nextTry, 3);
    });

    test('three failed tries on one bar offer a choice instead of a fourth rewind', () {
      final c = PracticeCoach();
      expect(c.onMistake(Verdict.wrongStep, 5), PracticeAction.rewind);
      expect(c.onMistake(Verdict.wrongStep, 6), PracticeAction.rewind); // same bar (beats 5-8)
      expect(c.onMistake(Verdict.missed, 7), PracticeAction.offerChoice);
      expect(c.bar, 2);
    });

    test('a different bar starts the count over', () {
      final c = PracticeCoach();
      c.onMistake(Verdict.wrongStep, 1);
      c.onMistake(Verdict.wrongStep, 1);
      expect(c.onMistake(Verdict.wrongStep, 5), PracticeAction.rewind);
      expect(c.nextTry, 2);
    });

    test('slow down gives fresh tries; keep going never rewinds that bar again', () {
      final c = PracticeCoach();
      for (var i = 0; i < 3; i++) {
        c.onMistake(Verdict.wrongStep, 1);
      }
      c.slowDown();
      expect(c.onMistake(Verdict.wrongStep, 1), PracticeAction.rewind);
      expect(c.onMistake(Verdict.wrongStep, 1), PracticeAction.rewind);
      expect(c.onMistake(Verdict.wrongStep, 1), PracticeAction.offerChoice);
      c.keepGoing();
      expect(c.onMistake(Verdict.wrongStep, 2), PracticeAction.carryOn);
      expect(c.onMistake(Verdict.wrongStep, 5), PracticeAction.rewind);
    });
  });
}
