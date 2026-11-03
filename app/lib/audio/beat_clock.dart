import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/preset.dart';

/// Plays the routine's music (or a generated metronome track when the preset
/// has none) and derives the beat clock from the player position, so the chart,
/// the nodes' schedule, and what the dancer hears all share one time base.
///
/// Beat 1 is at [t0AppMs] (wall clock, ms since epoch). The track starts
/// `countInBeats` before that.
class BeatClock extends ChangeNotifier {
  BeatClock(this.preset);

  final Preset preset;
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;

  int? t0AppMs;
  double _positionMs = 0;
  bool get playing => _player.playing;

  double get countInMs => preset.countInBeats * preset.beatMs;

  /// Current beat, 1-based and fractional; < 1 during the count-in.
  double get nowBeat => 1 + (_positionMs - countInMs) / preset.beatMs;

  /// Total beats the track covers after beat 1 (two beats of tail).
  double get endBeat => preset.lastBeat + 2;
  bool get finished => nowBeat >= endBeat;

  Future<void> prepare() async {
    if (preset.music != null) {
      await _player.setAsset('assets/music/${preset.music}');
    } else {
      final f = await _metronomeFile();
      await _player.setFilePath(f.path);
    }
    _posSub = _player.positionStream.listen((p) {
      _positionMs = p.inMilliseconds.toDouble();
      notifyListeners();
    });
  }

  /// Starts playback and returns the wall-clock time of beat 1. The player's
  /// actual start is measured, not assumed, so the nodes get an accurate t0.
  Future<int> start() async {
    final startWall = DateTime.now().millisecondsSinceEpoch;
    unawaited(_player.play());
    // Wait until the position actually advances, then back-date the start.
    final sw = Stopwatch()..start();
    while (_player.position.inMilliseconds < 5 && sw.elapsedMilliseconds < 1500) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final actualStart = DateTime.now().millisecondsSinceEpoch - _player.position.inMilliseconds;
    t0AppMs = (actualStart + countInMs).round();
    debugPrint('beat clock: requested $startWall, actual $actualStart, t0 $t0AppMs');
    notifyListeners();
    return t0AppMs!;
  }

  Future<void> pause() => _player.pause();

  /// Rewinds so that playback resumes `countInBeats` before `beat`, and returns
  /// the new wall-clock t0 for beat 1 (so the nodes can be restarted on it).
  Future<int> resumeFrom(double beat) async {
    final targetMs = max(0.0, (beat - 1) * preset.beatMs);
    await _player.seek(Duration(milliseconds: targetMs.round()));
    final wallBefore = DateTime.now().millisecondsSinceEpoch;
    unawaited(_player.play());
    final sw = Stopwatch()..start();
    while (_player.position.inMilliseconds < targetMs + 5 && sw.elapsedMilliseconds < 1500) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final actualStart = DateTime.now().millisecondsSinceEpoch - _player.position.inMilliseconds;
    t0AppMs = (actualStart + countInMs).round();
    debugPrint('beat clock: resume at beat $beat, wall $wallBefore, t0 $t0AppMs');
    notifyListeners();
    return t0AppMs!;
  }

  Future<void> stop() async {
    await _player.stop();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ---- metronome synthesis ---------------------------------------------------

  /// A WAV file with a click on every beat from the count-in to two beats past
  /// the last step. Beat 1 of every 4 is accented. Written once per preset/bpm.
  Future<File> _metronomeFile() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/metronome_${preset.id}_${preset.bpm.round()}.wav');
    if (await f.exists()) return f;

    const rate = 22050;
    final totalBeats = preset.countInBeats + endBeat;
    final nSamples = (totalBeats * preset.beatMs / 1000 * rate).ceil();
    final pcm = Int16List(nSamples);
    for (var b = 0; b < totalBeats.ceil(); b++) {
      final isCountIn = b < preset.countInBeats;
      final beatInBar = (b - preset.countInBeats) % 4;
      final accent = !isCountIn && beatInBar == 0;
      final freq = isCountIn ? 800.0 : (accent ? 1500.0 : 1000.0);
      final amp = isCountIn ? 0.5 : (accent ? 0.9 : 0.6);
      final start = (b * preset.beatMs / 1000 * rate).round();
      const clickMs = 35;
      const n = clickMs * rate ~/ 1000;
      for (var i = 0; i < n && start + i < nSamples; i++) {
        final t = i / rate;
        final env = exp(-t * 90);
        pcm[start + i] = (sin(2 * pi * freq * t) * env * amp * 32767).round();
      }
    }
    await f.writeAsBytes(_wav(pcm, rate));
    return f;
  }

  static Uint8List _wav(Int16List pcm, int rate) {
    final dataBytes = pcm.length * 2;
    final b = ByteData(44 + dataBytes);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, rate, Endian.little);
    b.setUint32(28, rate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      b.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }
}
