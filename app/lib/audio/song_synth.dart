import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/preset.dart';

/// What to render: tempo, bars and count-in, and which routine (its style
/// and key follow from the id). A record, so it can go to an isolate.
typedef SongSpec = ({double bpm, int beatsPerBar, int countIn, double beats, int id, bool waltz});

/// The backing track for a routine that has no music file: a short groove
/// made on the device at the routine's tempo, so each routine sounds like
/// its own song (on the song select and while dancing).
///
/// The beat is exact: beat 1 of the routine is the first sample after the
/// count-in (sticks), and every beat carries a sharp attack (a kick, or in a
/// waltz the bass and chord stabs), so the dancer can hear where to land.
abstract final class SongSynth {
  /// Bump when the sound changes, so cached files are made again.
  static const _version = 1;
  static const rate = 22050;

  /// The music style's name, for the song select.
  static String styleName(Preset p) => switch (_style(p.id, p.beatsPerBar == 3)) {
        _Style.waltz => 'Waltz',
        _Style.house => 'House',
        _Style.pop => 'Pop',
        _Style.latin => 'Latin',
      };

  /// The whole track for a session: count-in, the routine, two beats of tail.
  static Future<File> track(Preset p) =>
      _file('song_${p.id}_${(p.bpm * 100).round()}_${p.countInBeats}_${p.beatsPerBar}_${p.lastBeat.round()}', (
        bpm: p.bpm,
        beatsPerBar: p.beatsPerBar,
        countIn: p.countInBeats,
        beats: p.countInBeats + p.lastBeat + 2,
        id: p.id,
        waltz: p.beatsPerBar == 3,
      ));

  /// Eight bars with no count-in, to loop on the song select.
  static Future<File> preview(Preset p) => _file('preview_${p.id}_${(p.bpm * 100).round()}_${p.beatsPerBar}', (
        bpm: p.bpm,
        beatsPerBar: p.beatsPerBar,
        countIn: 0,
        beats: 8.0 * p.beatsPerBar,
        id: p.id,
        waltz: p.beatsPerBar == 3,
      ));

  static final _inTest = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  static Future<File> _file(String name, SongSpec spec) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${name}_v$_version.wav');
    if (await f.exists()) return f;
    // Off the UI thread, so a swipe on the song select does not stutter.
    // (Tests run it in place: an isolate does not finish in fake time.)
    final bytes = _inTest ? render(spec) : await compute(render, spec);
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
    return f;
  }

  static _Style _style(int id, bool waltz) => waltz ? _Style.waltz : _Style.values[1 + id % 3];

  /// The WAV file's bytes (16-bit mono).
  static Uint8List render(SongSpec s) {
    final beatSec = 60 / s.bpm;
    final n = (s.beats * beatSec * rate).ceil();
    final out = Float32List(n);
    final m = _Mixer(out, Random(s.id * 7919 + 13));
    double at(double beat) => beat * beatSec; // seconds from the start of the file

    // Count-in: sticks on every beat, the first one higher.
    for (var b = 0; b < s.countIn; b++) {
      m.sticks(at(b.toDouble()), b == 0 ? 1600 : 1200);
    }

    final style = _style(s.id, s.waltz);
    final bpb = s.beatsPerBar;
    // A key per routine (bass between A1 and G#2) and a four-chord loop.
    final root = 33 + (s.id * 7) % 12;
    final prog = _progressions[style]!;
    final bars = ((s.beats - s.countIn) / bpb).ceil();
    for (var bar = 0; bar < bars; bar++) {
      final b0 = s.countIn + bar * bpb.toDouble();
      final (offset, minor) = prog[bar % prog.length];
      final r = root + offset;
      final chord = [r + 24, r + 24 + (minor ? 3 : 4), r + 24 + 7];
      final fifth = r + 7;
      double t(double beat) => at(b0 + beat);
      if (bar % 8 == 0) m.crash(t(0));

      switch (style) {
        case _Style.waltz:
          m.kick(t(0), 0.9);
          m.bass(t(0), beatSec * 0.95, r, 0.55);
          m.bass(t(bpb == 3 ? 2 : 3), beatSec * 0.8, fifth, 0.3);
          for (var b = 1; b < bpb; b++) {
            m.stab(t(b.toDouble()), beatSec * 0.7, chord, 0.32);
            m.hat(t(b.toDouble()), 0.35);
          }
          m.pad(t(0), beatSec * bpb, chord, 0.08);
        case _Style.house:
          for (var b = 0; b < bpb; b++) {
            m.kick(t(b.toDouble()), 1);
            m.hat(t(b + 0.5), 0.45, open: true);
            m.bass(t(b + 0.5), beatSec * 0.4, r, 0.5);
            if (b.isOdd) m.snare(t(b.toDouble()), 0.55);
          }
          m.stab(t(1.5), beatSec * 0.35, chord, 0.3);
          m.stab(t(bpb - 0.5), beatSec * 0.35, chord, 0.26);
        case _Style.pop:
          for (var b = 0; b < bpb * 2; b++) {
            m.hat(t(b / 2), b.isEven ? 0.35 : 0.22);
          }
          for (var b = 0; b < bpb; b++) {
            if (b.isOdd) m.snare(t(b.toDouble()), 0.6);
            m.kick(t(b.toDouble()), b.isEven ? 1 : 0.85);
          }
          m.kick(t(2.5), 0.5);
          m.bass(t(0), beatSec * 0.9, r, 0.5);
          m.bass(t(1.5), beatSec * 0.4, r + 12, 0.3);
          m.bass(t(2), beatSec * 0.9, r, 0.45);
          m.bass(t(3), beatSec * 0.8, fifth, 0.4);
          m.stab(t(0), beatSec * 1.6, chord, 0.22);
          m.stab(t(2.5), beatSec * 1.2, chord, 0.18);
        case _Style.latin:
          for (var b = 0; b < bpb; b++) {
            m.kick(t(b.toDouble()), 0.95);
            m.hat(t(b + 0.5), 0.3);
            m.snare(t(b + 0.75), 0.4);
          }
          m.snare(t(1.5), 0.45);
          m.snare(t(3.5), 0.45);
          m.bass(t(0), beatSec * 0.7, r, 0.55);
          m.bass(t(0.75), beatSec * 0.7, r, 0.4);
          m.bass(t(2), beatSec * 0.7, fifth, 0.5);
          m.bass(t(2.75), beatSec * 0.7, r, 0.4);
          m.stab(t(1), beatSec * 0.3, chord, 0.24);
          m.stab(t(3), beatSec * 0.3, chord, 0.24);
      }
    }
    return _wav(m.master(), rate);
  }

  /// (semitones above the key, minor?) per bar.
  static const _progressions = {
    _Style.waltz: [(0, false), (9, true), (5, false), (7, false)], // I vi IV V
    _Style.house: [(0, true), (8, false), (3, false), (10, false)], // i VI III VII
    _Style.pop: [(0, true), (5, true), (8, false), (7, false)], // i iv VI V
    _Style.latin: [(0, true), (10, false), (8, false), (10, false)], // i VII VI VII
  };

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

enum _Style { waltz, house, pop, latin }

/// Simple drum and synth voices, added into one buffer.
class _Mixer {
  _Mixer(this.out, this.rnd);
  final Float32List out;
  final Random rnd;
  static const _rate = SongSynth.rate;

  static double _hz(int midi) => 440 * pow(2, (midi - 69) / 12).toDouble();

  /// Runs [f] (seconds since the note began) over [dur] seconds from [start].
  void _note(double start, double dur, double Function(double t) f) {
    final i0 = (start * _rate).round();
    final len = (dur * _rate).round();
    for (var i = 0; i < len && i0 + i < out.length; i++) {
      if (i0 + i >= 0) out[i0 + i] += f(i / _rate);
    }
  }

  double _noise() => rnd.nextDouble() * 2 - 1;

  void kick(double at, double amp) {
    var ph = 0.0;
    _note(at, 0.35, (t) {
      ph += 2 * pi * (45 + 115 * exp(-t * 32)) / _rate;
      final click = t < 0.004 ? _noise() * 0.25 : 0.0;
      return amp * (sin(ph) * exp(-t * 8) + click);
    });
  }

  void snare(double at, double amp) => _note(at, 0.22, (t) {
        return amp * (_noise() * exp(-t * 20) * 0.55 + sin(2 * pi * 185 * t) * exp(-t * 30) * 0.35);
      });

  void hat(double at, double amp, {bool open = false}) {
    var last = 0.0;
    _note(at, open ? 0.22 : 0.06, (t) {
      final n = _noise();
      final hp = n - last; // crude high-pass
      last = n;
      return amp * 0.35 * hp * exp(-t * (open ? 16 : 75));
    });
  }

  void crash(double at) {
    var last = 0.0;
    _note(at, 1.6, (t) {
      final n = _noise();
      final hp = n - last;
      last = n;
      return 0.16 * hp * exp(-t * 2.4);
    });
  }

  void sticks(double at, double hz) => _note(at, 0.05, (t) => 0.5 * sin(2 * pi * hz * t) * exp(-t * 90));

  void bass(double at, double dur, int midi, double amp) {
    final f = _hz(midi);
    _note(at, dur, (t) {
      final ph = 2 * pi * f * t;
      final env = min(1.0, t / 0.005) * (0.65 + 0.35 * exp(-t * 6)) * min(1.0, (dur - t) / 0.03);
      return amp * env * (sin(ph) + 0.35 * sin(2 * ph) + 0.12 * sin(3 * ph));
    });
  }

  /// A plucked chord: two slightly detuned saw-like voices per note.
  void stab(double at, double dur, List<int> notes, double amp) {
    for (final midi in notes) {
      final f = _hz(midi);
      _note(at, dur, (t) {
        var v = 0.0;
        for (final d in const [0.997, 1.003]) {
          final ph = 2 * pi * f * d * t;
          v += sin(ph) + sin(2 * ph) / 2 + sin(3 * ph) / 3 + sin(4 * ph) / 4;
        }
        final env = min(1.0, t / 0.004) * exp(-t * 7) * min(1.0, (dur - t) / 0.02);
        return amp * 0.18 * env * v;
      });
    }
  }

  /// A soft sustained chord under a waltz.
  void pad(double at, double dur, List<int> notes, double amp) {
    for (final midi in notes) {
      final f = _hz(midi - 12);
      _note(at, dur, (t) {
        final ph = 2 * pi * f * t;
        final env = min(1.0, t / 0.08) * min(1.0, (dur - t) / 0.08);
        return amp * env * (sin(ph) + 0.3 * sin(2 * ph));
      });
    }
  }

  /// Soft-clipped to 16 bits.
  Int16List master() {
    final pcm = Int16List(out.length);
    for (var i = 0; i < out.length; i++) {
      final v = out[i] * 0.7;
      final c = v.abs() < 1e-9 ? 0.0 : (exp(2 * v) - 1) / (exp(2 * v) + 1); // tanh
      pcm[i] = (c * 32000).round();
    }
    return pcm;
  }
}
