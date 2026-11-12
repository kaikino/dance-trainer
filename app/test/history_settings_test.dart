import 'dart:convert';
import 'dart:io';

import 'package:dance_trainer/models/session_kind.dart';
import 'package:dance_trainer/screens/summary_screen.dart';
import 'package:dance_trainer/store/history.dart';
import 'package:dance_trainer/store/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

void main() {
  late FakeDocuments docs;
  setUp(() {
    docs = FakeDocuments();
    PathProviderPlatform.instance = docs;
  });

  /// Writes a session.json the way SessionRecorder.end does.
  void session(String id, int day,
      {int preset = 1, String kind = 'performance', bool complete = true, double acc = 0.5, double first = 0.4}) {
    final dir = Directory('${docs.root.path}/sessions/$id')..createSync(recursive: true);
    File('${dir.path}/session.json').writeAsStringSync(jsonEncode({
      'session_id': id,
      'preset_id': preset,
      'preset_name': 'R$preset',
      'mode': 'dance',
      't0_app_ms': DateTime(2026, 11, day).millisecondsSinceEpoch,
      'score': {
        'kind': kind,
        'complete': complete,
        'judged': 10,
        'steps': 12,
        'accuracy': acc,
        'first_try_accuracy': first,
        'bpm_min': 77,
        'bpm_max': 96,
        'ended_at_ms': DateTime(2026, 11, day).millisecondsSinceEpoch,
      },
    }));
  }

  test('history reads scored sessions newest first, and skips captures and junk', () async {
    session('a', 1, acc: 0.6);
    session('b', 3, acc: 0.8);
    session('c', 2, preset: 2);
    // A capture session has no score block; a broken file is skipped.
    Directory('${docs.root.path}/sessions/cap').createSync(recursive: true);
    File('${docs.root.path}/sessions/cap/session.json').writeAsStringSync(jsonEncode({'session_id': 'cap', 'preset_id': 1}));
    Directory('${docs.root.path}/sessions/bad').createSync(recursive: true);
    File('${docs.root.path}/sessions/bad/session.json').writeAsStringSync('{not json');

    final all = await SessionHistory.load();
    expect(all.map((e) => e.sessionId), ['b', 'c', 'a']);
    final one = await SessionHistory.load(presetId: 1);
    expect(one.map((e) => e.sessionId), ['b', 'a']);
    expect(one.first.bpmMin, 77);
    expect(one.first.bpmMax, 96);
    expect(one.first.judged, 10);
  });

  test('the best counts complete runs only; Practice is scored right first time', () async {
    session('a', 1, acc: 0.6);
    session('b', 2, acc: 0.95, complete: false); // ended early: never the best
    session('c', 3, kind: 'practice', acc: 1.0, first: 0.7);
    final h = await SessionHistory.load(presetId: 1);
    expect(h.firstWhere((e) => e.sessionId == 'c').headline, 0.7);
    expect(SessionHistory.best(h), 0.7);
    expect(SessionHistory.bestByPreset(h), {1: 0.7});
    expect(SessionHistory.best(h.where((e) => !e.complete)), isNull);
  });

  test('vs last time: the previous complete run of the same routine and mode', () async {
    session('a', 1, acc: 0.63);
    session('b', 2, acc: 0.9, complete: false);
    session('p', 3, kind: 'practice');
    session('c', 4, acc: 0.79);
    final h = await SessionHistory.load(presetId: 1);
    final prev = SessionHistory.previous(h, presetId: 1, kind: SessionKind.performance, sessionId: 'c');
    expect(prev?.sessionId, 'a');
    expect(SessionHistory.previous(h, presetId: 1, kind: SessionKind.performance, sessionId: 'a'), isNull);
  });

  test('settings remember the routine, mode, tempo per mode and onboarding', () async {
    AppSettings.audioDelayMs = 210;
    AppSettings.audioDelayMeasured = true;
    AppSettings.onboardingSeen = true;
    AppSettings.lastPresetId = 3;
    AppSettings.lastKind = 'practice';
    AppSettings.tempoByKind = {'practice': 0.7, 'performance': 1.1};
    await AppSettings.save();

    AppSettings.onboardingSeen = false;
    AppSettings.lastPresetId = null;
    AppSettings.lastKind = null;
    AppSettings.tempoByKind = {};
    AppSettings.audioDelayMs = 0;
    await AppSettings.load();
    expect(AppSettings.audioDelayMs, 210);
    expect(AppSettings.audioDelayMeasured, isTrue);
    expect(AppSettings.onboardingSeen, isTrue);
    expect(AppSettings.lastPresetId, 3);
    expect(AppSettings.lastKind, 'practice');
    expect(AppSettings.tempoByKind, {'practice': 0.7, 'performance': 1.1});
  });

  test('a settings file from before these fields loads with defaults', () async {
    File('${docs.root.path}/settings.json').writeAsStringSync(jsonEncode({'audio_delay_ms': 180}));
    AppSettings.onboardingSeen = true;
    await AppSettings.load();
    expect(AppSettings.audioDelayMs, 180);
    expect(AppSettings.onboardingSeen, isFalse);
    expect(AppSettings.lastPresetId, isNull);
    expect(AppSettings.tempoByKind, isEmpty);
  });

  test('summary headline and timing advice', () {
    expect(summaryHeadline(0.8, previous: 0.63), 'Nice! Up from 63%');
    expect(summaryHeadline(0.96), 'Superb!');
    expect(summaryHeadline(0.6, previous: 0.7), 'Good effort! Last time 70%');
    expect(summaryHeadline(0.8, complete: false), 'Ended early');
    expect(summaryHeadline(null), 'No steps were judged');
    expect(timingAdvice(12), 'Right on the beat');
    expect(timingAdvice(80), startsWith('Slightly behind the beat'));
    expect(timingAdvice(-80), startsWith('Slightly ahead of the beat'));
  });
}
