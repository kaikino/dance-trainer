import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/preset.dart';
import 'beat_clock.dart';
import 'song_synth.dart';

/// The song select's music: loops the routine in the middle of the carousel
/// and crossfades (out, then in) when another one is swiped to.
class SongPreview {
  AudioPlayer? _player;
  int _gen = 0;
  Preset? _playing;

  static const _volume = 0.8;

  /// The routine playing (or about to), null when stopped.
  Preset? get current => _playing;

  /// Plays [p]'s music on a loop, at its tempo. A later [play] or [stop] wins.
  Future<void> play(Preset p) async {
    final gen = ++_gen;
    if (_playing != null && _sameSong(_playing!, p) && (_player?.playing ?? false)) return;
    _playing = p;
    try {
      final player = _player ??= AudioPlayer();
      await BeatClock.session();
      if (player.playing) await _fade(player, to: 0, gen: gen);
      if (gen != _gen) return;
      if (p.music != null) {
        await player.setAsset('assets/music/${p.music}');
        await player.setSpeed(p.tempo);
      } else {
        final f = await SongSynth.preview(p);
        if (gen != _gen) return;
        await player.setFilePath(f.path);
        await player.setSpeed(1);
      }
      if (gen != _gen) return;
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(0);
      unawaited(player.play().catchError((Object _) {}));
      await _fade(player, to: _volume, gen: gen);
    } catch (e) {
      debugPrint('song preview: $e');
    }
  }

  /// Fades out and stops.
  Future<void> stop() async {
    final gen = ++_gen;
    _playing = null;
    final player = _player;
    if (player == null) return;
    try {
      await _fade(player, to: 0, gen: gen);
      if (gen == _gen) await player.pause();
    } catch (e) {
      debugPrint('song preview: $e');
    }
  }

  void dispose() {
    _gen++;
    _player?.dispose();
    _player = null;
  }

  static bool _sameSong(Preset a, Preset b) => a.id == b.id && a.bpm == b.bpm && a.music == b.music;

  /// Ramps the volume over ~200 ms; gives up if something newer started.
  Future<void> _fade(AudioPlayer player, {required double to, required int gen}) async {
    final from = player.volume;
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      if (gen != _gen) return;
      await player.setVolume(from + (to - from) * i / steps);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}
