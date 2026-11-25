import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/models/session_score.dart';
import 'package:dance_trainer/ui/run_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 4/4 routine with one step per beat for [bars] bars, alternating feet.
Preset routine({int bars = 4}) => Preset(1, 'Test', 120, 4, [
      for (var b = 1; b <= bars * 4; b++) PresetStep(b.toDouble(), b.isOdd ? Role.left : Role.right, StepClass.forward),
    ]);

/// Scores step [i] of [p] with [v], [ms] late.
void judge(SessionScore s, Preset p, int i, Verdict v, {int ms = 0}) {
  final st = p.steps[i];
  s.add(st.foot, StepEvent(i + 1, 0, st.stepClass, 200, st.stepClass, ms, v), st.beat);
}

void main() {
  group('RunTimelineData', () {
    test('accuracy per bar and over two bars; steps not reached are left out', () {
      final p = routine();
      final s = SessionScore(p);
      // Bar 1 all correct, bar 2 half, bar 3 none correct; bar 4 not reached.
      for (var i = 0; i < 4; i++) {
        judge(s, p, i, Verdict.correct);
      }
      for (var i = 4; i < 8; i++) {
        judge(s, p, i, i.isEven ? Verdict.correct : Verdict.wrongStep);
      }
      for (var i = 8; i < 12; i++) {
        judge(s, p, i, i == 8 ? Verdict.missed : Verdict.offBeat, ms: 200);
      }
      final d = RunTimelineData(p, s);
      expect(d.bars, 4);
      expect(d.steps, hasLength(12));
      expect([for (var b = 1; b <= 4; b++) d.accuracyIn(b)], [1.0, 0.5, 0.0, null]);
      expect(d.rollingAccuracy(1), 1.0);
      expect(d.rollingAccuracy(2), 0.75);
      expect(d.rollingAccuracy(3), 0.25);
      expect(d.rollingAccuracy(4), 0.0, reason: 'bar 3 alone: bar 4 has nothing judged');
      expect(d.weakBars, [3, 2], reason: 'under 70 %, worst first');
      expect(d.offBeatIn(3), (late: 3, early: 0));
      expect(d.barStartBeat(3), 9.0);
      // The missed step has no timing; the others keep theirs.
      expect(d.steps.firstWhere((x) => x.verdict == Verdict.missed).timingMs, isNull);
      expect(d.steps.firstWhere((x) => x.verdict == Verdict.offBeat).timingMs, 200);
    });

    test('Practice is charted by first tries, and counts rewinds per bar', () {
      final p = routine(bars: 2);
      final s = SessionScore(p);
      for (var i = 0; i < 4; i++) {
        judge(s, p, i, Verdict.wrongStep);
      }
      s.rewind(1); // bar 1 again: right this time
      for (var i = 0; i < 4; i++) {
        judge(s, p, i, Verdict.correct);
      }
      expect(RunTimelineData(p, s).accuracyIn(1), 1.0, reason: 'Performance counts the latest');
      final practice = RunTimelineData(p, s, practice: true);
      expect(practice.accuracyIn(1), 0.0, reason: 'Practice counts the first try');
      expect(practice.rewinds, {1: 1});
    });
  });

  testWidgets('the weakest bar is shown first; tapping a bar shows it; Practice starts at its first beat', (t) async {
    final p = routine();
    final s = SessionScore(p);
    for (var i = 0; i < 16; i++) {
      judge(s, p, i, i >= 8 && i < 12 ? Verdict.wrongStep : Verdict.correct);
    }
    double? from;
    t.view.physicalSize = const Size(900, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: RunTimeline(data: RunTimelineData(p, s), onPractice: (b) => from = b),
        ),
      ),
    ));
    expect(find.textContaining('Bar 3'), findsOneWidget, reason: 'bar 3 had every step wrong');
    expect(find.text('0 of 4 correct'), findsOneWidget);

    // Bar 1 is the first quarter of the chart (after the 44 px axis).
    final box = t.getRect(find.byKey(RunTimeline.chartKey));
    await t.tapAt(Offset(box.left + 44 + (box.width - 52) * 0.1, box.top + 100));
    await t.pump();
    expect(find.text('Bar 1'), findsOneWidget);
    expect(find.text('4 of 4 correct'), findsOneWidget);

    await t.tap(find.text('Practice from here'));
    expect(from, 1.0);
  });

  testWidgets('a clean run says so', (t) async {
    final p = routine(bars: 1);
    final s = SessionScore(p);
    for (var i = 0; i < 4; i++) {
      judge(s, p, i, Verdict.correct);
    }
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RunTimeline(data: RunTimelineData(p, s), onPractice: (_) {}))));
    expect(find.textContaining('No weak bars'), findsOneWidget);
  });
}
