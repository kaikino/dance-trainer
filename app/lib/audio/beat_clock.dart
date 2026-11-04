import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/preset.dart';
import '../store/settings.dart';

/// Plays the routine's music (or a generated metronome track when the preset
/// has none) and keeps the beat clock that the chart and the nodes share.
///
/// The clock is the wall clock from the moment playback was requested, shifted
/// by [AppSettings.audioDelayMs]: the player's own position starts counting at
/// `play()`, but on Android the first sound comes out 100–300 ms later, so a
/// chart driven by the player position runs ahead of what the dancer hears.
///
/// Beat 1 is at [t0AppMs] (wall clock, ms since epoch, as heard). The track
/// starts `countInBeats` before that.
class BeatClock extends ChangeNotifier {
  BeatClock(this.preset);

  final Preset preset;
  final _player = AudioPlayer();
  Timer? _frame;

  int? t0AppMs;
  bool get playing => _player.playing;

  /// Track ms per wall ms: music is sped up or slowed for a tempo change; the
  /// metronome is generated at the new tempo and plays at normal speed.
  double get _rate => preset.music != null ? preset.tempo : 1.0;
  double get _fileBeatMs => preset.beatMs * _rate;
  double get _countInFileMs => preset.countInBeats * _fileBeatMs;

  // Playback was requested at wall time _anchorWallMs from track position
  // _anchorFileMs. While paused, the clock holds at _heldFileMs.
  double? _anchorWallMs;
  double _anchorFileMs = 0;
  double _heldFileMs = 0;

  static double _wallMs() => DateTime.now().microsecondsSinceEpoch / 1000.0;

  /// Track position the dancer is hearing right now.
  double get _heardFileMs {
    final a = _anchorWallMs;
    if (a == null) return _heldFileMs;
    return _anchorFileMs + max(0.0, _wallMs() - a - AppSettings.audioDelayMs) * _rate;
  }

  /// Current beat, 1-based and fractional; < 1 during the count-in.
  double get nowBeat => 1 + (_heardFileMs - _countInFileMs) / _fileBeatMs;

  /// Total beats the track covers after beat 1 (two beats of tail).
  double get endBeat => preset.lastBeat + 2;
  bool get finished => nowBeat >= endBeat;

  /// Wall time at which playback was last requested (for the sound-sync test).
  double? get anchorWallMs => _anchorWallMs;

  Future<void> prepare() async {
    if (preset.music != null) {
      await _player.setAsset('assets/music/${preset.music}');
      await _player.setSpeed(_rate);
    } else {
      final f = await _metronomeFile();
      await _player.setFilePath(f.path);
    }
  }

  /// Starts playback and returns the wall-clock time at which beat 1 is heard.
  Future<int> start() => _playFrom(0);

  Future<void> pause() async {
    _heldFileMs = _heardFileMs;
    _anchorWallMs = null;
    _frame?.cancel();
    await _player.pause();
    notifyListeners();
  }

  /// Rewinds so that playback resumes `countInBeats` before `beat`, and returns
  /// the new wall-clock t0 for beat 1 (so the nodes can be restarted on it).
  Future<int> resumeFrom(double beat) async {
    final targetMs = max(0.0, (beat - 1) * _fileBeatMs);
    await _player.seek(Duration(microseconds: (targetMs * 1000).round()));
    return _playFrom(targetMs);
  }

  Future<int> _playFrom(double fileMs) async {
    _anchorFileMs = fileMs;
    _anchorWallMs = _wallMs();
    unawaited(_player.play());
    // Beat 1 is heard when the track reaches the end of the count-in.
    t0AppMs = (_anchorWallMs! + AppSettings.audioDelayMs + (_countInFileMs - fileMs) / _rate).round();
    debugPrint('beat clock: play from ${fileMs.round()} ms, delay ${AppSettings.audioDelayMs} ms, t0 $t0AppMs');
    // Redraw every frame; the player's position stream updates too coarsely.
    _frame?.cancel();
    _frame = Timer.periodic(const Duration(milliseconds: 16), (_) => notifyListeners());
    notifyListeners();
    return t0AppMs!;
  }

  Future<void> stop() async {
    _frame?.cancel();
    _heldFileMs = _heardFileMs;
    _anchorWallMs = null;
    await _player.stop();
  }

  @override
  void dispose() {
    _frame?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ---- metronome synthesis ---------------------------------------------------

  /// A WAV file with a click on every beat from the count-in to two beats past
  /// the last step. Beat 1 of every 4 is accented. Written once per preset/bpm.
  Future<File> _metronomeFile() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/metronome_${preset.id}_${(preset.bpm * 100).round()}_${preset.countInBeats}.wav');
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
