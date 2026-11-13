import 'dart:convert';
import 'dart:io';

import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/chart/floor_plan.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:flutter_test/flutter_test.dart';

Preset load(String name) =>
    Preset.fromJson(jsonDecode(File('assets/presets/$name').readAsStringSync()) as Map<String, dynamic>);

void main() {
  final files = Directory('assets/presets').listSync().whereType<File>().where((f) => f.path.endsWith('.json'));

  for (final f in files) {
    final name = f.uri.pathSegments.last;
    test('$name: each foot is back where it started after one loop', () {
      final plan = FloorPlan(load(name));
      final end = plan.loopBeats + 0.3; // landed, before the next loop's first swing (0.6 beat early)
      for (final foot in Role.values) {
        final d = (plan.foot(foot, end).pos - plan.start[foot]!).distance;
        expect(d, lessThan(1e-9), reason: '$foot off by $d m');
      }
    });
  }

  test('box step: a 6-beat loop, the right foot lands forward and out on 2', () {
    final plan = FloorPlan(load('box_step.json'));
    expect(plan.loopBeats, 6);
    final r = plan.foot(Role.right, 2.0).pos;
    expect(r.dy, closeTo(FloorPlan.stride, 1e-9));
    expect(r.dx, greaterThan(FloorPlan.gap / 2));
  });

  test('grapevine: the left foot crosses behind and past the right', () {
    final plan = FloorPlan(load('grapevine.json'));
    final l = plan.foot(Role.left, 2.0).pos, r = plan.foot(Role.right, 2.0).pos;
    expect(l.dy, lessThan(r.dy));
    expect(l.dx, greaterThan(r.dx));
  });

  test('a swing lifts the foot and lands on the beat', () {
    final plan = FloorPlan(load('basic_step.json'));
    expect(plan.foot(Role.left, 0.75).lift, greaterThan(0.5));
    expect(plan.foot(Role.left, 1.0).lift, 0);
    expect(plan.upcoming(1.0, 1).single.beat, 2.0);
  });
}
