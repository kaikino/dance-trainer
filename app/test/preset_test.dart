import 'dart:convert';
import 'dart:io';

import 'package:dance_trainer/ble/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every preset must be danceable (docs/preset-format.md):
///  - a foot may only travel while the other foot can hold the weight. A
///    traveling step puts the weight on the stepping foot; in_place may or may
///    not (a step in place or a tap); a kick leaves it on the other foot.
///  - over one loop, each foot's forward and sideways travel adds up to zero,
///    so the loop can repeat without the feet drifting apart.
/// Travel units: forward/back 1, side_out/side_in 1 sideways, cross 2 inward
/// (past the other foot, so it needs a side step or two to undo).
void main() {
  final dir = Directory('assets/presets');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();

  test('there are presets', () => expect(files, isNotEmpty));

  for (final f in files) {
    test('${f.uri.pathSegments.last} is danceable', () {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final steps = (j['steps'] as List).cast<Map<String, dynamic>>();
      final problems = danceProblems(steps, loop: j['loop'] == true);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  test('the old box step is caught', () {
    final box = [
      for (final (b, foot, cls) in [
        (1, 'L', 'forward'), (2, 'R', 'side_out'), (3, 'L', 'in_place'),
        (4, 'R', 'back'), (5, 'L', 'side_out'), (6, 'R', 'in_place'),
      ])
        {'beat': b, 'foot': foot, 'class': cls},
    ];
    expect(danceProblems(box, loop: true), isNotEmpty);
  });
}

List<String> danceProblems(List<Map<String, dynamic>> steps, {required bool loop}) {
  final problems = <String>[];
  final ordered = [...steps]..sort((a, b) => (a['beat'] as num).compareTo(b['beat'] as num));
  // Which feet may be holding the weight right now. Both at the start.
  var weight = {'L', 'R'};
  final fwd = {'L': 0, 'R': 0}, out = {'L': 0, 'R': 0};
  // Two passes when looping, so the step from the end back to the start is checked.
  for (var pass = 0; pass < (loop ? 2 : 1); pass++) {
    for (final s in ordered) {
      final foot = s['foot'] as String, other = foot == 'L' ? 'R' : 'L';
      final cls = stepClassNames[s['class']];
      if (cls == null) {
        problems.add('beat ${s['beat']}: unknown class ${s['class']}');
        continue;
      }
      if (!weight.contains(other)) {
        problems.add('beat ${s['beat']}: $foot ${s['class']} while all the weight is on $foot');
      }
      if (pass == 0) {
        switch (cls) {
          case StepClass.forward:
            fwd[foot] = fwd[foot]! + 1;
          case StepClass.back:
            fwd[foot] = fwd[foot]! - 1;
          case StepClass.sideOut:
            out[foot] = out[foot]! + 1;
          case StepClass.sideIn:
            out[foot] = out[foot]! - 1;
          case StepClass.cross:
            out[foot] = out[foot]! - 2;
          case StepClass.inPlace || StepClass.kick || StepClass.none:
            break;
        }
      }
      weight = switch (cls) {
        StepClass.inPlace => {'L', 'R'},
        StepClass.kick || StepClass.none => {other},
        _ => {foot},
      };
    }
  }
  if (loop) {
    for (final foot in ['L', 'R']) {
      if (fwd[foot] != 0 || out[foot] != 0) {
        problems.add('$foot ends each loop ${fwd[foot]} forward and ${out[foot]} outward, so the feet drift');
      }
    }
  }
  return problems;
}
