import 'dart:io';

import 'package:dance_trainer/ble/fake_node.dart';
import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/models/session_kind.dart';
import 'package:dance_trainer/models/session_score.dart';
import 'package:dance_trainer/screens/dance/dance_session.dart';
import 'package:dance_trainer/store/history.dart';
import 'package:dance_trainer/store/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

// Session races and edge cases found in round 5 (S1-S8 in the review).

/// One bar at 240 bpm: a second of count-in and two of steps, so a whole
/// session runs in a few seconds of real time.
Preset _short({int id = 5}) => Preset.fromJson({
      'id': id,
      'name': 'Short',
      'bpm': 240,
      'loop': true,
      'repeats': 2,
      'steps': [
        {'beat': 1.0, 'foot': 'L', 'class': 'forward'},
        {'beat': 2.0, 'foot': 'R', 'class': 'in_place'},
        {'beat': 3.0, 'foot': 'L', 'class': 'back'},
        {'beat': 4.0, 'foot': 'R', 'class': 'in_place'},
      ],
    });

Future<NodeManager> _nodes({double pWrong = 0, bool connect = true}) async {
  final m = NodeManager(fake: true);
  for (final n in m.nodes) {
    (n as FakeNodeClient)
      ..pMissed = 0
      ..pWrong = pWrong
      ..pLate = 0;
  }
  if (connect) await m.scanAndConnect();
  return m;
}

Future<void> _disconnect(NodeManager m) async {
  for (final n in m.nodes) {
    await n.disconnect();
  }
}

/// Ticks [s] like the screen's Ticker until [done] or [timeout].
Future<void> _run(DanceSession s, bool Function() done, {Duration timeout = const Duration(seconds: 12)}) async {
  final until = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(until)) {
    s.tick();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue, reason: 'timed out');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeDocuments docs;
  setUp(() {
    docs = FakeDocuments();
    PathProviderPlatform.instance = docs;
    AppSettings.audioDelayMs = 0;
    DanceSession.practicePauseTime = const Duration(milliseconds: 50);
  });
  tearDown(() => DanceSession.practicePauseTime = const Duration(milliseconds: 2500));
  installFakeAudio();

  Directory sessionsDir() => Directory('${docs.root.path}/sessions');
  bool playing(DanceSession s) => s.clock.anchorWallMs != null;
  bool nodesIdle(NodeManager m) => m.nodes.every((n) => n.status!.mode == Mode.idle);

  test('a pause right after Resume wins: the session stays paused (S1)', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    await s.begin();
    await _run(s, () => s.clock.nowBeat > 1.5);
    s.pause('The music was interrupted by another app or a call.');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final r = s.resumeFrom(s.hold!.fromBeat);
    s.pause('The app went to the background.');
    await r;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.hold, isA<PausedHold>());
    expect((s.hold as PausedHold).reason, contains('background'));
    expect(playing(s), isFalse, reason: 'music stays stopped');
    expect(nodesIdle(m), isTrue, reason: 'nodes stay stopped');
    // And Resume then works.
    await s.resumeFrom(s.hold!.fromBeat);
    expect(s.hold, isNull);
    expect(playing(s), isTrue);
    await s.end();
    s.dispose();
    await _disconnect(m);
  });

  test('a pause during a practice rewind\'s restart is not lost (S1)', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.practice, dancer: 't');
    await s.begin();
    await _run(s, () => s.clock.nowBeat > 1.5);
    // As the rewind does after showing the mistake.
    s.hold = const MistakeHold(Verdict.wrongStep, 'Wrong step', 'x', 1, 2);
    final r = s.resumeFrom(1);
    s.pause('The app went to the background.');
    await r;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.hold, isA<PausedHold>());
    expect(s.hold!.fromBeat, 1);
    expect(playing(s), isFalse);
    expect(nodesIdle(m), isTrue);
    await s.end();
    s.dispose();
    await _disconnect(m);
  });

  test('a pause while the nodes are being started stops them again (S1)', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    await s.begin();
    await _run(s, () => s.clock.nowBeat > 1.5);
    s.pause('bg');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final r = s.resumeFrom(1);
    // Let the music start, then pause while the node starts are awaited.
    await _run(s, () => s.hold == null);
    s.pause('again');
    await r;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.hold, isA<PausedHold>());
    expect(playing(s), isFalse);
    expect(nodesIdle(m), isTrue);
    await s.end();
    s.dispose();
    await _disconnect(m);
  });

  test('backgrounded while getting ready: waits paused instead of starting unseen (S2)', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    bool? recorded;
    s.onEnded = (r) => recorded = r;
    final b = s.begin();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(s.phase, SessionPhase.preparing);
    s.pause('The app went to the background.');
    await b;
    expect(s.phase, SessionPhase.running);
    expect(s.hold, isA<PausedHold>());
    expect(s.hold!.fromBeat, 1);
    expect(playing(s), isFalse);
    expect(nodesIdle(m), isTrue);
    expect(s.needsFrames, isFalse);
    await s.resumeFrom(1);
    expect(playing(s), isTrue);
    await _run(s, () => recorded != null);
    expect(recorded, isTrue);
    expect(s.score.judged, 8);
    s.dispose();
    await _disconnect(m);
  });

  test('End while a resume is seeking: the music does not start after it (S3)', () async {
    final m = await _nodes(connect: false);
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't', demo: true);
    await s.begin();
    await _run(s, () => s.clock.nowBeat > 1);
    s.pause('Paused to read the steps.');
    final r = s.resumeFrom(1);
    await s.end();
    await r;
    expect(playing(s), isFalse);
    s.dispose();
  });

  test('a tempo change keeps the bpm the node can hold (S4)', () {
    final p = _short();
    var q = p;
    for (var k = 0; k < 4; k++) {
      q = q.withTempo(0.8);
      expect(q.bpm * 10, closeTo((q.bpm * 10).roundToDouble(), 1e-9), reason: 'a whole bpm_x10');
      expect(q.bpm, closeTo(p.bpm * q.tempo, 1e-9), reason: 'music speed matches the bpm');
    }
    expect(_short().withTempo(0.8).withTempo(0.8).bpm, 153.6);
    expect(
        Preset.fromJson({
          'id': 1,
          'name': 'b',
          'bpm': 96,
          'steps': [
            {'beat': 1, 'foot': 'L', 'class': 'forward'}
          ]
        }).withTempo(0.8).withTempo(0.8).bpm,
        61.4);
  });

  test('ended before the music started: nothing saved, nothing to summarise (S6)', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    bool? recorded;
    s.onEnded = (r) => recorded = r;
    final b = s.begin();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(s.phase, SessionPhase.preparing);
    await s.end();
    await b;
    expect(recorded, isFalse);
    expect(nodesIdle(m), isTrue);
    expect(sessionsDir().existsSync() ? sessionsDir().listSync() : const [], isEmpty);
    expect(await SessionHistory.load(), isEmpty);
    s.dispose();
    await _disconnect(m);
  });

  test('ended while paused before starting: nothing saved (S2 + S6)', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    bool? recorded;
    s.onEnded = (r) => recorded = r;
    final b = s.begin();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    s.pause('bg');
    await b;
    await s.end();
    expect(recorded, isFalse);
    expect(await SessionHistory.load(), isEmpty);
    s.dispose();
    await _disconnect(m);
  });

  test('Keep going past a bar: the run is saved as incomplete (S8)', () async {
    final m = await _nodes(pWrong: 1);
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.practice, dancer: 't');
    bool? recorded;
    s.onEnded = (r) => recorded = r;
    await s.begin();
    await _run(s, () => s.hold is ChoiceHold);
    for (final n in m.nodes) {
      (n as FakeNodeClient).pWrong = 0;
    }
    await s.keepGoing(1);
    await _run(s, () => recorded != null);
    expect(recorded, isTrue);
    final h = await SessionHistory.load();
    expect(h.single.complete, isFalse);
    s.dispose();
    await _disconnect(m);
  });

  test('a correct step followed by a stray tap stays correct (S5)', () async {
    final p = Preset.fromJson({
      'id': 2,
      'name': 'f',
      'bpm': 132,
      'steps': [
        {'beat': 1, 'foot': 'L', 'class': 'forward'},
        {'beat': 2, 'foot': 'L', 'class': 'back'},
      ],
    });
    final beatMs = p.beatMs;
    final sc = SessionScore(p);
    // What the node sends: beat 1 correct; a tap 200 ms later judged against
    // beat 2 (254 ms early, wrong class); the real beat-2 step, an extra.
    sc.addStrike(Role.left, StepEvent(0, 0, StepClass.forward, 220, StepClass.forward, 0, Verdict.correct),
        strikeMs: 0, beatMs: beatMs);
    sc.addStrike(Role.left,
        StepEvent(1, 0, StepClass.forward, 220, StepClass.back, (200 - beatMs).truncate(), Verdict.wrongStep),
        strikeMs: 200, beatMs: beatMs);
    sc.addStrike(Role.left, StepEvent(2, 0, StepClass.back, 220, StepClass.none, 0, Verdict.extra),
        strikeMs: 455, beatMs: beatMs);
    expect(sc.latest[0]!.verdict, Verdict.correct);
    expect(sc.latest[1]!.verdict, Verdict.wrongStep);
    expect(sc.extras, 1);
    // A missed step is placed at its own beat (the node reports the step time).
    final sc2 = SessionScore(p);
    expect(
        sc2
            .addStrike(Role.left, StepEvent(0, 0, StepClass.none, 0, StepClass.back, 0, Verdict.missed),
                strikeMs: beatMs, beatMs: beatMs)
            .step,
        1);
  });
}
