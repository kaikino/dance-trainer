import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dance_trainer/audio/song_synth.dart';
import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/main.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/screens/preset_screen.dart';
import 'package:dance_trainer/store/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

/// Loudness (RMS) of [ms] milliseconds of the track from [atSec].
double rms(Int16List pcm, double atSec, double ms) {
  final i0 = (atSec * SongSynth.rate).round();
  final n = (ms / 1000 * SongSynth.rate).round();
  var s = 0.0;
  for (var i = max(0, i0); i < min(pcm.length, i0 + n); i++) {
    s += pcm[i] * pcm[i].toDouble();
  }
  return sqrt(s / n);
}

Int16List pcmOf(Uint8List wav) => Int16List.view(Uint8List.fromList(wav.sublist(44)).buffer);

void main() {
  // Every style: house, pop and latin by id, a waltz for 3/4.
  for (final (id, bpb) in [(3, 4), (4, 4), (5, 4), (5, 3)]) {
    test('id $id in $bpb/4: a 16-bit WAV of the right length, and every beat lands on its sample', () {
      const bpm = 96.0, countIn = 4, beats = 4 + 16.0;
      final wav =
          SongSynth.render((bpm: bpm, beatsPerBar: bpb, countIn: countIn, beats: beats, id: id, waltz: bpb == 3));
      final b = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(b.getUint32(24, Endian.little), SongSynth.rate);
      final pcm = pcmOf(wav);
      const beatSec = 60 / bpm;
      expect(pcm.length, closeTo(beats * beatSec * SongSynth.rate, 2));
      // Count-in sticks and every beat after: louder just after the beat than just before.
      for (var k = 0; k < beats - 1; k++) {
        final t = k * beatSec;
        final after = rms(pcm, t, 25), before = rms(pcm, t - 0.03, 25);
        expect(after, greaterThan(before * 1.3 + 200), reason: 'beat $k at ${t.toStringAsFixed(3)} s');
      }
      // Loud but not crushed against the ceiling.
      final peak = pcm.map((v) => v.abs()).reduce(max);
      expect(peak, inInclusiveRange(12000, 32000));
    });
  }

  test('routines get different music: style by id, waltz for 3/4', () {
    Preset p(int id, int bpb) =>
        Preset(id, 'p', 96, 4, const [PresetStep(1, Role.left, StepClass.forward)], beatsPerBar: bpb);
    expect(
        {
          for (final id in [3, 4, 5]) SongSynth.styleName(p(id, 4))
        }.length,
        3);
    expect(SongSynth.styleName(p(4, 3)), 'Waltz');
  });

  group('song select', () {
    final docs = FakeDocuments();
    setUpAll(() {
      PathProviderPlatform.instance = docs;
      installFakeAudio();
    });

    testWidgets('swiping moves to the next routine, which becomes the selection, and its music is made', (t) async {
      AppSettings.lastPresetId = null;
      AppSettings.musicPreview = true;
      rootBundle.clear();
      final m = NodeManager(fake: true);
      await t.runAsync(m.scanAndConnect);
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(DanceTrainerApp(manager: m, home: PresetScreen(manager: m)));
      Future<void> settle() async {
        for (var i = 0; i < 15; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await settle();
      expect(find.byType(PageView), findsOneWidget);
      expect(find.text('Basic forward and back'), findsOneWidget, reason: 'the first routine starts in the middle');
      List<String> previews() => docs.root
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.startsWith('preview_') && n.endsWith('.wav'))
          .toList();
      final before = previews().length;
      expect(before, greaterThanOrEqualTo(1), reason: 'the routine in the middle plays');

      await t.fling(find.byType(PageView), const Offset(-400, 0), 1500);
      await settle();
      expect(AppSettings.lastPresetId, 5, reason: 'the swiped-to routine (Box step) is selected');
      expect(previews().length, before + 1, reason: 'its own music was made for the preview');

      // Tapping the routine to the left goes back to it.
      await t.tap(find.text('Basic forward and back'));
      await settle();
      expect(AppSettings.lastPresetId, 3);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 30));
    });
  });
}
