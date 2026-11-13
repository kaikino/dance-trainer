import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../ble/protocol.dart';

/// One scheduled step, expanded over repeats. `beat` is 1-based.
class PresetStep {
  final double beat;
  final Role foot;
  final StepClass stepClass;
  const PresetStep(this.beat, this.foot, this.stepClass);
}

/// A choreography from presets/*.json (see docs/preset-format.md).
class Preset {
  final int id;
  final String name;
  final double bpm;
  final int countInBeats;
  final List<PresetStep> steps; // expanded over `repeats`
  final String? music; // file name under assets/music/, or null for a metronome
  final double tempo; // 1.0 = as written; the music plays at this speed
  final int beatsPerBar; // time signature: 4 (4/4), 3 (3/4, a waltz box step)

  const Preset(this.id, this.name, this.bpm, this.countInBeats, this.steps,
      {this.music, this.tempo = 1.0, this.beatsPerBar = 4});

  /// Same routine at a scaled tempo (Practice mode slow-down). The bpm is
  /// rounded to 0.1, the resolution the node keeps (bpm_x10 on the wire), and
  /// the music speed is derived from it, so the music, the chart and the
  /// node's beat all agree exactly.
  Preset withTempo(double factor) {
    final baseBpm = bpm / tempo;
    final newBpm = (bpm * factor * 10).round() / 10;
    return Preset(id, name, newBpm, countInBeats, steps,
        music: music, tempo: newBpm / baseBpm, beatsPerBar: beatsPerBar);
  }

  static Future<Preset> loadAsset(String path) async =>
      Preset.fromJson(jsonDecode(await rootBundle.loadString(path)) as Map<String, dynamic>);

  factory Preset.fromJson(Map<String, dynamic> j) {
    final raw = (j['steps'] as List).cast<Map<String, dynamic>>();
    final loop = j['loop'] == true;
    final repeats = loop ? (j['repeats'] as int? ?? 1) : 1;
    // One loop lasts length_beats (lets a pattern end on a rest), else whole
    // bars up to its last step.
    final bpb = j['beats_per_bar'] as int? ?? 4;
    final lastBeat = raw.map((s) => (s['beat'] as num).toDouble()).reduce((a, b) => a > b ? a : b);
    final patternBeats = (j['length_beats'] as num?)?.toDouble() ?? (lastBeat / bpb).ceil() * bpb.toDouble();
    final steps = <PresetStep>[];
    for (var r = 0; r < repeats; r++) {
      for (final s in raw) {
        steps.add(PresetStep(
          (s['beat'] as num).toDouble() + r * patternBeats,
          s['foot'] == 'L' ? Role.left : Role.right,
          stepClassNames[s['class']]!,
        ));
      }
    }
    return Preset(
        j['id'] as int, j['name'] as String, (j['bpm'] as num).toDouble(), j['count_in_beats'] as int? ?? 4, steps,
        music: j['music'] as String?, beatsPerBar: bpb);
  }

  double get beatMs => 60000 / bpm;
  double get lastBeat => steps.map((s) => s.beat).reduce((a, b) => a > b ? a : b);

  /// Milliseconds after t0 (beat 1) at which `beat` happens.
  double beatToMs(double beat) => (beat - 1) * beatMs;

  /// The schedule entries for one node, optionally only from [fromBeat] on
  /// (a practice rewind restarts the nodes mid-routine).
  List<(double, StepClass)> scheduleFor(Role foot, {double fromBeat = 1}) =>
      steps.where((s) => s.foot == foot && s.beat >= fromBeat).map((s) => (s.beat, s.stepClass)).toList();

  /// Indices into [steps] per foot, in beat order (built once per step list).
  static final _byFoot = Expando<Map<Role, List<int>>>();
  Map<Role, List<int>> get _footIndex => _byFoot[steps] ??= {
        for (final f in Role.values)
          f: [
            for (var i = 0; i < steps.length; i++)
              if (steps[i].foot == f) i
          ]..sort((a, b) => steps[a].beat.compareTo(steps[b].beat)),
      };

  /// Indices into [steps] in beat order (ties keep the file order).
  static final _byBeat = Expando<List<int>>();
  List<int> get beatOrder => _byBeat[steps] ??= [for (var i = 0; i < steps.length; i++) i]..sort((a, b) {
      final c = steps[a].beat.compareTo(steps[b].beat);
      return c != 0 ? c : a.compareTo(b);
    });

  /// The scheduled step for [foot] nearest to [beat], at most [within] beats
  /// away, ignoring steps before [fromBeat]. Null when none is that close.
  int? nearestStep(Role foot, double beat, {required double within, double fromBeat = double.negativeInfinity}) {
    final idx = _footIndex[foot]!;
    // First entry at or after beat - within (binary search).
    var lo = 0, hi = idx.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (steps[idx[mid]].beat < beat - within) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    int? best;
    var bestErr = double.infinity;
    for (var k = lo; k < idx.length; k++) {
      final s = steps[idx[k]];
      if (s.beat > beat + within) break;
      if (s.beat < fromBeat) continue;
      final err = (s.beat - beat).abs();
      if (err < bestErr) {
        bestErr = err;
        best = idx[k];
      }
    }
    return best;
  }

  /// Bars from beat 1 to the last step.
  int get bars => barOf(lastBeat, beatsPerBar);

  /// First beat of the bar that [beat] falls in.
  double barStart(double beat) => ((beat - 1) ~/ beatsPerBar) * beatsPerBar + 1.0;
}

/// Bar numbers are 1-based; beat 1 is the first beat of bar 1.
int barOf(double beat, int beatsPerBar) => (beat - 1) ~/ beatsPerBar + 1;
