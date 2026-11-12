import 'dart:convert';
import 'dart:io';

import 'package:dance_trainer/ble/clock_sync.dart';
import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/store/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

/// A node the test drives by hand: it sends exactly the batches and events given.
class _ScriptedNode extends NodeClient {
  _ScriptedNode(super.role);
  @override
  bool get connected => true;
  void batch(int t0, {required bool gyro, int value = 1}) => emitBatch(StreamBatch(t0, [
        for (var i = 0; i < StreamBatch.samplesPerBatch; i++)
          gyro
              ? StreamSample(0x7fff / 16384.0, 0, 0, 0, value, value, value, true)
              : StreamSample(1, 0, 0, 0, value, value, 1000, false),
      ]));
  void event(int tNodeUs) => emitEvent(StepEvent(0, tNodeUs, StepClass.forward, 200, StepClass.none, 0, Verdict.unjudged));
  @override
  Future<int> syncTime({int rounds = 8}) async => offsetUs!;
  @override
  Future<void> pushSchedule(int presetId, double bpm, List<(double, StepClass)> steps) async {}
  @override
  Future<void> start(Mode mode, int t0AppMs) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> calibrate() async {}
  @override
  Future<void> cancelCalibration() async {}
  @override
  Future<void> buzzTest(Haptic h) async {}
  @override
  Future<void> setThreshold(int conf) async {}
  @override
  Future<void> setWindow(int ms) async {}
  @override
  Future<void> disconnect() async {}
}

/// A NodeManager whose left node is [node]; the right one never connects.
class _OneNode extends NodeManager {
  _OneNode(this.node) : super(fake: true);
  final _ScriptedNode node;
  @override
  NodeClient get left => node;
}

final _preset = Preset.fromJson({
  'id': 3,
  'name': 'Test',
  'bpm': 120,
  'steps': [
    {'beat': 1.0, 'foot': 'L', 'class': 'forward'},
    {'beat': 3.0, 'foot': 'L', 'class': 'back'},
  ],
});

List<List<String>> _rows(File f) =>
    [for (final l in f.readAsLinesSync().skip(1)) l.split(',')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = FakeDocuments();

  group('capture recording', () {
    late _ScriptedNode node;
    late SessionRecorder rec;
    // Node clock 1000 s ahead of the app clock, mod 2^32.
    const offsetUs = 1000000000;
    int nodeNow() => (DateTime.now().millisecondsSinceEpoch * 1000 + offsetUs) & 0xffffffff;

    setUp(() async {
      node = _ScriptedNode(Role.left)..offsetUs = offsetUs;
      rec = SessionRecorder(preset: _preset, dancer: 't', mode: Mode.capture, nodes: _OneNode(node));
      await rec.begin();
    });

    test('rows need both halves: unpaired accel or gyro halves are dropped, never half written', () async {
      final t = nodeNow();
      node.batch(t - 400000, gyro: false); // idle-mode accel before Start: no gyro partner ever
      node.batch(t - 300000, gyro: false, value: 7); // a pair, gyro second
      node.batch(t - 300000, gyro: true, value: 8);
      node.batch(t - 200000, gyro: true, value: 9); // gyro whose accel was lost
      node.batch(t + 900000, gyro: false); // 1.2 s later: the stale halves are let go
      await Future<void>.delayed(Duration.zero);
      await rec.end();

      final lines = File('${rec.dir.path}/L.csv').readAsLinesSync();
      expect(lines.first, 't_node_us,ax,ay,az,gx,gy,gz,qw,qx,qy,qz,t_app_ms');
      final rows = _rows(File('${rec.dir.path}/L.csv'));
      expect(rows, hasLength(StreamBatch.samplesPerBatch));
      for (final r in rows) {
        expect(r, hasLength(12));
        expect(r.where((v) => v.isEmpty || v.toLowerCase().contains('nan')), isEmpty);
        expect(r.sublist(1, 7), ['7', '7', '1000', '8', '8', '8']);
      }
      expect(rec.sampleCounts[Role.left], StreamBatch.samplesPerBatch);
    });

    test('rows are 1/104 s apart and carry app time', () async {
      final t0 = nodeNow();
      final appT0 = DateTime.now().millisecondsSinceEpoch + nodeMsAfter(t0, DateTime.now().millisecondsSinceEpoch, offsetUs);
      node
        ..batch(t0, gyro: false)
        ..batch(t0, gyro: true);
      await Future<void>.delayed(Duration.zero);
      await rec.end();
      final rows = _rows(File('${rec.dir.path}/L.csv'));
      final tNode = [for (final r in rows) int.parse(r[0])];
      final tApp = [for (final r in rows) double.parse(r[11])];
      for (var i = 0; i < rows.length; i++) {
        expect(u32DeltaUs(tNode[i], t0), (i * 1e6 / 104).round());
        expect(tApp[i], closeTo(appT0 + i * 1000 / 104, 1.5));
      }
    });

    test('events carry app time, across the node clock wrap and a new offset after a reconnect', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      node.event((now * 1000 + offsetUs) & 0xffffffff);
      await Future<void>.delayed(Duration.zero);
      // The node rebooted: a new clock and a new offset, near its wrap.
      node.offsetUs = 0xffffffff - now * 1000 % 0x100000000 - 50000;
      rec.noteNode(node);
      node.event(((now + 100) * 1000 + node.offsetUs!) & 0xffffffff);
      await Future<void>.delayed(Duration.zero);
      await rec.end();

      final lines = File('${rec.dir.path}/events.csv').readAsLinesSync();
      expect(lines.first.split(',').last, 't_app_ms');
      final tApp = [for (final l in lines.skip(1)) double.parse(l.split(',').last)];
      expect(tApp[0], closeTo(now.toDouble(), 2));
      expect(tApp[1], closeTo(now + 100.0, 2));
      final meta = jsonDecode(File('${rec.dir.path}/session.json').readAsStringSync()) as Map<String, dynamic>;
      expect(meta['clock_syncs'], hasLength(1)); // the first one was never noted: only the reconnect
      expect(meta['nodes']['L']['offset_us'], node.offsetUs);
    });
  });

  test('dance-mode rows: 1/52 s apart, no gyro columns, no gyro batches', () async {
    final node = _ScriptedNode(Role.left)..offsetUs = 0;
    final rec = SessionRecorder(preset: _preset, dancer: 't', mode: Mode.dance, nodes: _OneNode(node));
    await rec.begin();
    final t0 = (DateTime.now().millisecondsSinceEpoch * 1000) & 0xffffffff;
    node
      ..batch(t0, gyro: false)
      ..batch(t0, gyro: true);
    await Future<void>.delayed(Duration.zero);
    await rec.end();
    final rows = _rows(File('${rec.dir.path}/L.csv'));
    expect(rows, hasLength(StreamBatch.samplesPerBatch));
    expect(u32DeltaUs(int.parse(rows[1][0]), int.parse(rows[0][0])), (1e6 / 52).round());
    expect(rows.first.sublist(4, 7), ['', '', '']);
    expect(rows.first.last, isNot(isEmpty));
  });

  test('a whole capture session with fake nodes: every row complete and in time order', () async {
    final m = NodeManager(fake: true);
    await m.scanAndConnect();
    await m.syncAll();
    final rec = SessionRecorder(preset: _preset, dancer: 't', mode: Mode.capture, nodes: m);
    await rec.begin();
    // Idle streaming first (no gyro), then capture.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final t0 = DateTime.now().millisecondsSinceEpoch + 200;
    rec.addSegment(t0);
    for (final n in m.nodes) {
      await n.pushSchedule(_preset.id, _preset.bpm, _preset.scheduleFor(n.role));
      await n.start(Mode.capture, t0);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    for (final n in m.nodes) {
      await n.stop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await rec.end();
    for (final n in m.nodes) {
      await n.disconnect();
    }

    for (final foot in ['L', 'R']) {
      final rows = _rows(File('${rec.dir.path}/$foot.csv'));
      expect(rows.length, greaterThan(100));
      expect(rows.where((r) => r.length != 12 || r.any((v) => v.isEmpty || v.contains('NaN'))), isEmpty);
      final tApp = [for (final r in rows) double.parse(r[11])];
      for (var i = 1; i < tApp.length; i++) {
        expect(tApp[i], greaterThan(tApp[i - 1]));
      }
    }
  });
}
