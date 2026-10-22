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

  const Preset(this.id, this.name, this.bpm, this.countInBeats, this.steps);

  static Future<Preset> loadAsset(String path) async =>
      Preset.fromJson(jsonDecode(await rootBundle.loadString(path)) as Map<String, dynamic>);

  factory Preset.fromJson(Map<String, dynamic> j) {
    final raw = (j['steps'] as List).cast<Map<String, dynamic>>();
    final loop = j['loop'] == true;
    final repeats = loop ? (j['repeats'] as int? ?? 1) : 1;
    final patternBeats = raw.map((s) => (s['beat'] as num).toDouble()).reduce((a, b) => a > b ? a : b);
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
    return Preset(j['id'] as int, j['name'] as String, (j['bpm'] as num).toDouble(),
        j['count_in_beats'] as int? ?? 4, steps);
  }

  double get beatMs => 60000 / bpm;
  double get lastBeat => steps.map((s) => s.beat).reduce((a, b) => a > b ? a : b);

  /// Milliseconds after t0 (beat 1) at which `beat` happens.
  double beatToMs(double beat) => (beat - 1) * beatMs;

  /// The schedule entries for one node.
  List<(double, StepClass)> scheduleFor(Role foot) =>
      steps.where((s) => s.foot == foot).map((s) => (s.beat, s.stepClass)).toList();
}
