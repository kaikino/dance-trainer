import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:dance_trainer/ble/fake_node.dart';
import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/models/session_kind.dart';
import 'package:dance_trainer/screens/dance/dance_session.dart';
import 'package:dance_trainer/store/history.dart';
import 'package:dance_trainer/store/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

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
  });
  installFakeAudio();

  Directory sessionsDir() => Directory('${docs.root.path}/sessions');

  test('a performance runs to the end, scores every step and is saved as complete', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    bool? recorded;
    s.onEnded = (r) => recorded = r;
    await s.begin();
    expect(s.phase, SessionPhase.running);
    expect(m.nodes.every((n) => n.status!.mode == Mode.dance), isTrue);
    await _run(s, () => recorded != null);
    expect(recorded, isTrue);
    expect(s.score.judged, 8);
    expect(s.score.count(Verdict.correct), 8);
    expect(m.nodes.every((n) => n.status!.mode == Mode.idle), isTrue, reason: 'nodes stopped at the end');

    final history = await SessionHistory.load(presetId: 5);
    expect(history, hasLength(1));
    expect(history.single.complete, isTrue);
    expect(history.single.kind, SessionKind.performance);
    expect(history.single.headline, 1.0);
    expect(SessionHistory.best(history), 1.0);
    s.dispose();
    await _disconnect(m);
  });

  test('a session ended early is saved as incomplete and never counts as the best', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    bool? recorded;
    s.onEnded = (r) => recorded = r;
    await s.begin();
    await _run(s, () => s.score.judged >= 2);
    await s.end();
    expect(recorded, isTrue);
    final history = await SessionHistory.load(presetId: 5);
    expect(history.single.complete, isFalse);
    expect(history.single.headline, isNotNull);
    expect(SessionHistory.best(history), isNull);
    expect(SessionHistory.bestByPreset(history), isEmpty);
    s.dispose();
    await _disconnect(m);
  });

  test('watch first touches no node and records nothing', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.practice, dancer: 't', demo: true);
    bool? recorded;
    s.onEnded = (r) => recorded = r;
    await s.begin();
    expect(s.phase, SessionPhase.running);
    expect(s.scoring, isFalse);
    await _run(s, () => s.callout.isNotEmpty);
    expect(s.callout.first.foot, Role.left);
    expect(s.callout.first.stepClass, StepClass.forward);
    for (final n in m.nodes) {
      expect(n.offsetUs, isNull, reason: 'never clock-synced');
      expect(n.status!.mode, Mode.idle, reason: 'never started');
    }
    await _run(s, () => recorded != null);
    expect(recorded, isFalse);
    expect(s.recorder.begun, isFalse);
    expect(sessionsDir().existsSync(), isFalse);
    s.dispose();
    await _disconnect(m);
  });

  test('watch first works with no node connected', () async {
    final m = await _nodes(connect: false);
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't', demo: true);
    await s.begin();
    expect(s.phase, SessionPhase.running);
    s.dispose();
  });

  test('without nodes a real session fails to start instead of hanging', () async {
    final m = await _nodes(connect: false);
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    await s.begin();
    expect(s.phase, SessionPhase.error);
    expect(s.error, contains('No ankle node'));
    s.dispose();
  });

  test('practice: a wrong step rewinds its bar; three in a row offer a choice', () async {
    DanceSession.practicePauseTime = const Duration(milliseconds: 50);
    final m = await _nodes(pWrong: 1);
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.practice, dancer: 't');
    await s.begin();
    await _run(s, () => s.hold is MistakeHold);
    expect((s.hold as MistakeHold).fromBeat, 1);
    expect(m.nodes.every((n) => n.status!.mode == Mode.idle), isTrue, reason: 'nodes stopped while held');
    await _run(s, () => s.hold is ChoiceHold);
    expect(s.score.rewinds, 2);
    await s.keepGoing(1);
    expect(s.hold, isNull);
    expect(s.score.fromBeat, 5);
    await s.end();
    s.dispose();
    await _disconnect(m);
    DanceSession.practicePauseTime = const Duration(milliseconds: 2500);
  });

  test('an audio interruption pauses the session, and its end does not resume it', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    await s.begin();
    await _run(s, () => s.clock.nowBeat > 0);
    s.clock.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.pause));
    expect(s.hold, isA<PausedHold>());
    expect((s.hold as PausedHold).reason, contains('interrupted'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(m.nodes.every((n) => n.status!.mode == Mode.idle), isTrue);

    final held = s.clock.nowBeat;
    s.clock.onAudioInterruption(AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(s.clock.nowBeat, held, reason: 'the clock stays held');
    expect(s.hold, isA<PausedHold>());
    expect(s.needsFrames, isFalse, reason: 'no frames while paused');

    // Resume is the dancer's call.
    await s.resumeFrom(s.hold!.fromBeat);
    expect(s.hold, isNull);
    expect(s.needsFrames, isTrue);
    await s.end();
    s.dispose();
    await _disconnect(m);
  });

  test('ducking is left alone; unplugged headphones pause', () async {
    final m = await _nodes();
    final s = DanceSession(manager: m, preset: _short(), kind: SessionKind.performance, dancer: 't');
    await s.begin();
    s.clock.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.duck));
    expect(s.hold, isNull);
    s.clock.onBecomingNoisy();
    expect(s.hold, isA<PausedHold>());
    await s.end();
    s.dispose();
    await _disconnect(m);
  });
}
