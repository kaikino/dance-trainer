import 'package:flutter_test/flutter_test.dart';

import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';

void main() {
  group('protocol encoders', () {
    test('step event parses 12 bytes little-endian', () {
      final e = StepEvent.parse([
        0x05, 0x00, // seq 5
        0x40, 0xE2, 0x01, 0x00, // t = 123456
        0x02, // forward
        0xA0, // conf 160
        0x02, // expected forward
        0xF6, 0xFF, // timing -10 ms
        0x01, // correct
      ]);
      expect(e.seq, 5);
      expect(e.tStrikeNodeUs, 123456);
      expect(e.stepClass, StepClass.forward);
      expect(e.confidence, 160);
      expect(e.timingErrMs, -10);
      expect(e.verdict, Verdict.correct);
    });

    test('schedule header + one chunk', () {
      final chunks = encodeSchedule(1, 100.0, [(1.0, StepClass.forward), (3.0, StepClass.inPlace)]);
      expect(chunks.length, 2);
      expect(chunks[0], [0x01, 0x01, 0x00, 0xE8, 0x03, 0x02, 0x00]); // header, id 1, bpm 1000, n 2
      expect(chunks[1], [0x02, 0x64, 0x00, 0x02, 0x2C, 0x01, 0x01]); // last, beat 100 fwd, beat 300 in_place
    });

    test('start command carries mode and t0', () {
      expect(encodeStart(Mode.dance, 0x01020304), [0x01, 0x02, 0x04, 0x03, 0x02, 0x01]);
    });
  });

  group('preset', () {
    final p = Preset.fromJson({
      'id': 9,
      'name': 'Test',
      'bpm': 120,
      'count_in_beats': 4,
      'loop': true,
      'repeats': 2,
      'steps': [
        {'beat': 1.0, 'foot': 'L', 'class': 'forward'},
        {'beat': 2.0, 'foot': 'R', 'class': 'back'},
      ],
    });

    test('expands repeats with continuing beats', () {
      expect(p.steps.map((s) => s.beat).toList(), [1.0, 2.0, 3.0, 4.0]);
    });

    test('per-foot schedule', () {
      expect(p.scheduleFor(Role.left), [(1.0, StepClass.forward), (3.0, StepClass.forward)]);
    });

    test('beat timing', () {
      expect(p.beatToMs(3.0), 1000.0);
    });
  });
}
