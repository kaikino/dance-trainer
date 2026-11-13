import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/store/recording.dart';
import 'package:flutter_test/flutter_test.dart';

/// A synthetic capture run: 20 s at 104 Hz on both feet, a step every 0.625 s.
Directory fakeRun() {
  final d = Directory.systemTemp.createTempSync('run');
  const t0 = 1760985000000.0;
  File('${d.path}/session.json').writeAsStringSync(jsonEncode({
    'session_id': '20261113-101500-kai',
    'dancer': 'kai',
    'preset_name': 'Box step',
    'mode': 'capture',
    't0_app_ms': t0 + 2000,
    'segments': [
      {'from_beat': 1.0, 't0_app_ms': t0 + 2000, 'bpm': 96},
    ],
  }));
  final rnd = Random(1);
  for (final f in ['L', 'R']) {
    final b = StringBuffer('t_node_us,ax,ay,az,gx,gy,gz,qw,qx,qy,qz,t_app_ms\n');
    for (var i = 0; i < 2080; i++) {
      final t = i / 104;
      if (f == 'R' && i > 1000 && i < 1010) continue; // a dropout
      final ph = ((t - 2 + (f == 'R' ? 0.625 : 0)) % 1.25) / 1.25;
      final swing = ph < 0.4 ? sin(ph / 0.4 * pi) : 0.0;
      final az = 1000 + 600 * swing + (ph > 0.4 && ph < 0.43 ? 900 : 0) + rnd.nextInt(30);
      b.writeln('${i * 9615},${(300 * swing).round()},${rnd.nextInt(40) - 20},${az.round()},'
          '${(1500 * swing).round()},${(-2500 * swing).round()},${rnd.nextInt(60) - 30},'
          '16300,${(1200 * swing).round()},0,0,${(t0 + t * 1000).toStringAsFixed(1)}');
    }
    File('${d.path}/$f.csv').writeAsStringSync(b.toString());
  }
  final e = StringBuffer(
      't_strike_node_us,foot,step_class,confidence,expected_class,timing_err_ms,verdict,label_class,label_source,t_app_ms\n');
  for (var k = 0; k < 28; k++) {
    final f = k.isEven ? 'L' : 'R';
    final cls = k % 7 == 3 ? 4 : 2;
    e.writeln('0,$f,$cls,200,2,0,0,2,capture,${t0 + 2000 + k * 625 + 500}');
  }
  File('${d.path}/events.csv').writeAsStringSync(e.toString());
  return d;
}

void main() {
  test('a run reads back: both feet, steps, beats, a dropout', () async {
    final r = await Recording.load(fakeRun());
    expect(r.feet.keys, containsAll([Role.left, Role.right]));
    expect(r.feet[Role.left]!.rateHz, closeTo(104, 1));
    expect(r.feet[Role.right]!.gaps, 1);
    expect(r.feet[Role.left]!.gyr, isNotNull);
    expect(r.feet[Role.left]!.acc[2].first, closeTo(1.0, 0.05)); // mg -> g
    expect(r.strikes.length, 28);
    expect(r.strikes.where((s) => s.cls != StepClass.values[s.label]).length, 4);
    expect(r.beats.first, closeTo(2.0, 1e-6));
    expect(r.beats[1] - r.beats[0], closeTo(60 / 96, 1e-6));
    expect(r.duration, closeTo(20, 0.1));
  });
}
