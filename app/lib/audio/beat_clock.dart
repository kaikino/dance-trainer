import 'dart:async';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/preset.dart';
import '../store/settings.dart';
import 'song_synth.dart';

/// Plays the routine's music (or its generated backing track, [SongSynth],
/// when the preset has none) and keeps the beat clock that the chart and the nodes share.
///
/// The clock is the wall clock from the moment playback was requested, shifted
/// by [AppSettings.audioDelayMs]: the player's own position starts counting at
/// `play()`, but on Android the first sound comes out 100–300 ms later, so a
/// chart driven by the player position runs ahead of what the dancer hears.
///
/// Beat 1 is at [t0AppMs] (wall clock, ms since epoch, as heard). The track
/// starts `countInBeats` before that.
///
/// The clock does not tick by itself: read [nowBeat] once a frame (a Ticker).
/// Listeners hear about play, pause and stop.
class BeatClock extends ChangeNotifier {
  BeatClock(this.preset) {
    _playerSub = _player.playerStateStream.listen((s) {
      // The player stopped while the clock thought it was playing (the output
      // went away, a player error).
      if (_anchorWallMs != null && !s.playing && s.processingState != ProcessingState.completed) {
        _interrupt();
      }
    });
    unawaited(session().then((session) {
      if (_disposed) return;
      _sessionSubs
        ..add(session.interruptionEventStream.listen(onAudioInterruption))
        ..add(session.becomingNoisyEventStream.listen((_) => onBecomingNoisy()));
    }).catchError((Object _) {}));
  }

  final Preset preset;

  /// just_audio's own interruption handling is off: it pauses on a call and
  /// then plays again by itself when the call ends, while the dance screen
  /// says Paused and the nodes are stopped. This clock pauses instead and
  /// leaves resuming to the dancer.
  final _player = AudioPlayer(handleInterruptions: false);
  late final StreamSubscription<PlayerState> _playerSub;
  final _sessionSubs = <StreamSubscription<dynamic>>[];
  bool _disposed = false;

  /// The app's audio session, set up once as music playback (the song
  /// select's preview uses it too).
  static Future<AudioSession>? _configured;
  static Future<AudioSession> session() => _configured ??= AudioSession.instance.then((s) async {
        await s.configure(const AudioSessionConfiguration.music());
        return s;
      });

  /// Called when playback stops without [pause] or [stop] being asked for:
  /// audio focus lost (a call, another app), headphones unplugged. The clock
  /// has already paused; it never resumes by itself.
  VoidCallback? onInterrupted;

  int? t0AppMs;

  /// Another app or a call took the audio. Only the start of an interruption
  /// matters: the end is ignored (the dancer presses Resume). Ducking is left
  /// to the system.
  @visibleForTesting
  void onAudioInterruption(AudioInterruptionEvent e) {
    if (e.begin && e.type != AudioInterruptionType.duck) _interrupt();
  }

  /// Headphones or a speaker went away: stop rather than blare from the device.
  @visibleForTesting
  void onBecomingNoisy() => _interrupt();

  void _interrupt() {
    if (_anchorWallMs == null || _disposed) return;
    unawaited(pause());
    onInterrupted?.call();
  }

  /// Track ms per wall ms: music is sped up or slowed for a tempo change; the
  /// generated track is made at the new tempo and plays at normal speed.
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
      final f = await SongSynth.track(preset);
      await _player.setFilePath(f.path);
    }
  }

  /// Starts playback and returns the wall-clock time at which beat 1 is heard.
  Future<int> start() => _playFrom(0);

  Future<void> pause() async {
    _gen++;
    _heldFileMs = _heardFileMs;
    _anchorWallMs = null;
    await _player.pause();
    notifyListeners();
  }

  /// Rewinds so that playback resumes `countInBeats` before `beat`, and returns
  /// the new wall-clock t0 for beat 1 (so the nodes can be restarted on it).
  /// A [pause] or [stop] while seeking wins: the music then stays stopped
  /// (the returned t0 is never heard; the caller has been paused or ended).
  Future<int> resumeFrom(double beat) async {
    final gen = _gen;
    final targetMs = max(0.0, (beat - 1) * _fileBeatMs);
    try {
      await _player.seek(Duration(microseconds: (targetMs * 1000).round()));
    } catch (e) {
      // A stop aborts a seek under way (PlatformException abort).
      if (gen == _gen && !_disposed) rethrow;
    }
    return _playFrom(targetMs, gen);
  }

  /// Bumped by [pause] and [stop]: a resume that was seeking meanwhile must
  /// not start the music after it.
  int _gen = 0;

  Future<int> _playFrom(double fileMs, [int? gen]) async {
    final wall = _wallMs();
    // Beat 1 is heard when the track reaches the end of the count-in.
    final t0 = (wall + AppSettings.audioDelayMs + (_countInFileMs - fileMs) / _rate).round();
    if (_disposed || (gen != null && gen != _gen)) return t0;
    _anchorFileMs = fileMs;
    _anchorWallMs = wall;
    unawaited(_player.play().catchError((Object e) => debugPrint('beat clock: play failed: $e')));
    t0AppMs = t0;
    debugPrint('beat clock: play from ${fileMs.round()} ms, delay ${AppSettings.audioDelayMs} ms, t0 $t0');
    notifyListeners();
    return t0;
  }

  Future<void> stop() async {
    _gen++;
    _heldFileMs = _heardFileMs;
    _anchorWallMs = null;
    await _player.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _sessionSubs) {
      s.cancel();
    }
    _playerSub.cancel();
    _player.dispose();
    super.dispose();
  }
}
