// The app's wire format against the firmware itself: test/native/judge_harness.c
// builds the node's judge.c for the host, takes the packets the app writes and
// prints the structs and events the node would send. Skipped without a C compiler.
import 'dart:io';
import 'dart:typed_data';

import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/models/session_score.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

String? _compiler() {
  for (final cc in ['cc', 'gcc', 'clang']) {
    try {
      if (Process.runSync(cc, ['--version']).exitCode == 0) return cc;
    } catch (_) {}
  }
  return null;
}

void main() {
  final cc = _compiler();
  late String harness;

  setUpAll(() {
    if (cc == null) return;
    final out = Directory.systemTemp.createTempSync('judge_harness');
    harness = '${out.path}/judge_harness';
    final r = Process.runSync(cc, [
      '-std=c11',
      '-Itest/native',
      '-I../firmware/dance_node/src',
      '-o',
      harness,
      'test/native/judge_harness.c',
    ]);
    if (r.exitCode != 0) fail('judge harness does not build:\n${r.stderr}');
  });

  Future<List<String>> run(List<String> lines) async {
    final p = await Process.start(harness, []);
    p.stdin.write(lines.map((l) => '$l\n').join());
    await p.stdin.close();
    final out = await p.stdout.transform(const SystemEncoding().decoder).join();
    await p.exitCode;
    return out.split('\n').where((l) => l.isNotEmpty).toList();
  }

  String tagged(List<String> out, String tag) => out.firstWhere((l) => l.startsWith('$tag ')).substring(tag.length + 1);
  List<StepEvent> events(List<String> out) =>
      [for (final l in out.where((l) => l.startsWith('E '))) StepEvent.parse(_unhex(l.substring(2)))];
  List<int> scheduledUs(List<String> out) =>
      [for (final l in out.where((l) => l.startsWith('JS '))) int.parse(l.split(' ')[1])];

  final skip = cc == null ? 'no C compiler' : null;

  test('the node\'s structs parse in Dart', () async {
    final out = await run([]);
    final st = Status.parse(_unhex(tagged(out, 'STATUS')));
    expect(st.protocolVersion, protocolVersion);
    expect(st.role, Role.right);
    expect(st.fwVersion, 7);
    expect(st.batteryPct, 83);
    expect(st.mode, Mode.dance);
    expect(st.calibrated && st.knowsForward && !st.boardMoved, isTrue);
    expect(st.calPhase, CalPhase.back);
    expect(st.calSlides, 2);
    expect(st.calSpreadDeg, 11);
    final ts = TimeSyncReply.parse(_unhex(tagged(out, 'TS')));
    expect(ts.tAppMs, 0xfedcba98);
    expect(ts.tNodeUs, 0x89abcdef);
    final b = StreamBatch.parse(_unhex(tagged(out, 'BATCH')));
    expect(b.t0NodeUs, 0xfffffff0);
    expect(b.samples[0].qw, closeTo(1, 1e-3));
    expect(b.samples[1].qx, closeTo(0.7071, 1e-3));
    expect(b.samples[3].qw, closeTo(-1, 1e-3));
    expect(b.samples[0].ax, -1234);
    expect(b.samples[0].ay, 15900);
    expect(b.samples.every((s) => !s.isGyro), isTrue);
    final g = StreamBatch.parse(_unhex(tagged(out, 'GYRO')));
    expect(g.samples.every((s) => s.isGyro), isTrue);
    expect(g.samples[0].ax, -19999);
    expect(g.samples[0].ay, 20000);
  }, skip: skip);

  test('step classes match dt_protocol.h, in wire order', () {
    final h = File('../firmware/dance_node/src/dt_protocol.h').readAsStringSync();
    final body = RegExp(r'typedef enum \{([^}]*)\} dt_step_class_t;').firstMatch(h)!.group(1)!;
    final names = [
      for (final m in RegExp(r'DT_CLASS_(\w+)').allMatches(body))
        if (m.group(1) != 'COUNT') m.group(1)!.toLowerCase(),
    ];
    expect(names, [for (final c in StepClass.values) stepClassNames.entries.firstWhere((e) => e.value == c).key]);
  });

  test('a schedule and start written by the app drive the node\'s judge; its events parse back', () async {
    final p = Preset.fromJson({
      'id': 513,
      'name': 'x',
      'bpm': 96,
      'loop': true,
      'repeats': 8,
      'steps': [
        {'beat': 1, 'foot': 'L', 'class': 'forward'},
        {'beat': 2.5, 'foot': 'L', 'class': 'side_in'},
        {'beat': 3, 'foot': 'R', 'class': 'kick'},
        {'beat': 4, 'foot': 'L', 'class': 'cross'},
      ],
    });
    final sched = p.scheduleFor(Role.left);
    final chunks = encodeSchedule(p.id, p.bpm, sched);
    expect(chunks.every((c) => c.length <= 20), isTrue, reason: 'one link-layer packet each');
    const t0 = 0xfffff000; // the node clock wraps right after t0
    final out = await run([
      for (final c in chunks) 'S ${_hex(c)}',
      'C ${_hex(encodeStart(Mode.dance, t0))}',
      // On step 0; 200 ms late on step 1 with the wrong class; then far ahead.
      'K ${(t0 + 300000) & 0xffffffff} $t0 2 220',
      'K ${(t0 + 1500 * 625 + 500000) & 0xffffffff} ${(t0 + 1500 * 625 + 200000) & 0xffffffff} 3 220',
      'T ${(t0 + 6000000) & 0xffffffff}',
    ]);
    final j = tagged(out, 'J');
    expect(j, contains('bpm_x10=960'));
    expect(j, contains('n=${sched.length}'));
    final js = out.where((l) => l.startsWith('JS ')).map((l) => l.split(' ')).toList();
    for (var i = 0; i < sched.length; i++) {
      final want = (t0 + ((sched[i].$1 - 1) * 625000).round()) & 0xffffffff;
      expect((int.parse(js[i][1]) - want) & 0xffffffff, lessThan(100), reason: 'step $i time');
      expect(int.parse(js[i][2]), sched[i].$2.index);
    }
    final ev = events(out);
    expect(ev[0].verdict, Verdict.correct);
    expect(ev[0].expectedClass, StepClass.forward);
    expect(ev[1].verdict, Verdict.wrongStep);
    expect(ev[1].timingErrMs, 200);
    expect(ev[1].expectedClass, StepClass.sideIn);
    expect(ev.skip(2).every((e) => e.verdict == Verdict.missed && e.stepClass == StepClass.none), isTrue);
    expect([for (final e in ev) e.seq], List.generate(ev.length, (i) => i));
  }, skip: skip);

  test('Practice slow-down tempos: the node keeps the same beat as the app', () async {
    final base = Preset.fromJson({
      'id': 1,
      'name': 'b',
      'bpm': 96,
      'loop': true,
      'repeats': 16,
      'steps': [
        {'beat': 1, 'foot': 'L', 'class': 'forward'},
        {'beat': 3, 'foot': 'L', 'class': 'back'},
      ],
    });
    // Practice at 80 %, then Slow down twice.
    final slow = base.withTempo(0.8).withTempo(0.8).withTempo(0.8);
    final sched = slow.scheduleFor(Role.left);
    const t0 = 1000000;
    final out = await run([
      for (final c in encodeSchedule(slow.id, slow.bpm, sched)) 'S ${_hex(c)}',
      'C ${_hex(encodeStart(Mode.dance, t0))}'
    ]);
    final js = scheduledUs(out);
    for (var i = 0; i < sched.length; i++) {
      final appUs = t0 + slow.beatToMs(sched[i].$1) * 1000;
      expect((js[i] - appUs).abs(), lessThan(1000), reason: 'beat ${sched[i].$1}: node vs app/music');
    }
  }, skip: skip);

  test('a stray tap after a step: the app scores the step the node judged', () async {
    final p = Preset.fromJson({
      'id': 2,
      'name': 'f',
      'bpm': 132,
      'steps': [
        {'beat': 1, 'foot': 'L', 'class': 'forward'},
        {'beat': 2, 'foot': 'L', 'class': 'back'},
      ],
    });
    const t0 = 1000000;
    const beatUs = 60e6 / 132;
    final out = await run([
      for (final c in encodeSchedule(p.id, p.bpm, p.scheduleFor(Role.left))) 'S ${_hex(c)}',
      'C ${_hex(encodeStart(Mode.dance, t0))}',
      'K ${t0 + 300000} $t0 2 220', // forward, on beat 1
      'K ${t0 + 500000} ${t0 + 200000} 2 220', // a second tap 200 ms later
      'K ${t0 + beatUs.round() + 300000} ${t0 + beatUs.round()} 3 220', // back, on beat 2
      'T ${t0 + 4000000}',
    ]);
    final sc = SessionScore(p);
    for (final e in events(out)) {
      sc.addStrike(Role.left, e, strikeMs: (e.tStrikeNodeUs - t0) / 1000, beatMs: p.beatMs);
    }
    // The node: beat 1 correct, the tap judged (wrong) against beat 2, the real
    // beat-2 step an extra. The app must agree, not overwrite beat 1.
    expect(sc.latest[0]!.verdict, Verdict.correct);
    expect(sc.latest[1]!.verdict, Verdict.wrongStep);
    expect(sc.extras, 1);
  }, skip: skip);
}
