import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';

/// One recorded step, as written to events.csv (docs/data-format.md).
class RecordedEvent {
  final Role foot;
  final StepEvent ev;
  int labelClass;
  String labelSource;
  RecordedEvent(this.foot, this.ev, this.labelClass, this.labelSource);
}

/// Records one session to a folder in the app's documents directory, in the
/// exact layout ml/ reads: session.json, L.csv, R.csv, events.csv.
class SessionRecorder {
  SessionRecorder({
    required this.preset,
    required this.dancer,
    required this.mode,
    required this.nodes,
  });

  final Preset preset;
  final String dancer;
  final Mode mode;
  final NodeManager nodes;

  late final String sessionId;
  late final Directory dir;
  int? t0AppMs;
  final events = <RecordedEvent>[];
  final _subs = <StreamSubscription<dynamic>>[];
  final _sinks = <Role, IOSink>{};
  // Capture mode interleaves an accel batch and a gyro batch with the same t0;
  // rows wait here until both halves have arrived.
  final _pending = <Role, Map<int, List<List<num?>>>>{};

  int get sampleMs => mode == Mode.capture ? 10 : 20;

  Future<void> begin() async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    sessionId =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}-$dancer';
    final docs = await getApplicationDocumentsDirectory();
    dir = Directory('${docs.path}/sessions/$sessionId');
    await dir.create(recursive: true);

    for (final n in nodes.nodes.where((n) => n.connected)) {
      final sink = File('${dir.path}/${n.roleLabel}.csv').openWrite();
      sink.writeln('t_node_us,ax,ay,az,gx,gy,gz,qw,qx,qy,qz');
      _sinks[n.role] = sink;
      _pending[n.role] = {};
      _subs.add(n.batches.listen((b) => _onBatch(n.role, b)));
      _subs.add(n.events.listen((e) => _onEvent(n.role, e)));
    }
  }

  void _onBatch(Role role, StreamBatch b) {
    final pend = _pending[role]!;
    final rows = pend.putIfAbsent(b.t0NodeUs, () => List.generate(StreamBatch.samplesPerBatch, (i) {
          final t = b.t0NodeUs + i * sampleMs * 1000;
          return <num?>[t, null, null, null, null, null, null, null, null, null, null];
        }));
    for (var i = 0; i < b.samples.length; i++) {
      final s = b.samples[i];
      if (s.isGyro) {
        rows[i][4] = s.ax; rows[i][5] = s.ay; rows[i][6] = s.az;
      } else {
        rows[i][1] = s.ax; rows[i][2] = s.ay; rows[i][3] = s.az;
        rows[i][7] = (s.qw * 16384).round(); rows[i][8] = (s.qx * 16384).round();
        rows[i][9] = (s.qy * 16384).round(); rows[i][10] = (s.qz * 16384).round();
      }
    }
    final complete = mode != Mode.capture || (rows[0][1] != null && rows[0][4] != null);
    if (complete) {
      _flush(role, rows);
      pend.remove(b.t0NodeUs);
    }
    // Drop half-batches older than a second so a lost notify does not leak.
    pend.removeWhere((t0, r) {
      final stale = b.t0NodeUs - t0 > 1000000;
      if (stale) _flush(role, r);
      return stale;
    });
  }

  void _flush(Role role, List<List<num?>> rows) {
    final sink = _sinks[role];
    if (sink == null) return;
    for (final r in rows) {
      sink.writeln(r.map((v) => v == null ? '' : (v is double ? v.toStringAsFixed(4) : '$v')).join(','));
    }
  }

  void _onEvent(Role role, StepEvent e) {
    var label = -1;
    var source = '';
    if (mode == Mode.capture && t0AppMs != null) {
      // Label from the schedule: nearest scheduled beat for this foot within 250 ms.
      final node = role == Role.left ? nodes.left : nodes.right;
      final tAppMs = (e.tStrikeNodeUs - (node.offsetUs ?? 0)) / 1000.0;
      final beatT = tAppMs - t0AppMs!;
      PresetStep? best;
      var bestErr = double.infinity;
      for (final s in preset.steps.where((s) => s.foot == role)) {
        final err = (preset.beatToMs(s.beat) - beatT).abs();
        if (err < bestErr) {
          bestErr = err;
          best = s;
        }
      }
      if (best != null && bestErr <= 250) {
        label = best.stepClass.index;
        source = 'capture';
      }
    }
    events.add(RecordedEvent(role, e, label, source));
  }

  Future<void> end({String appVersion = '0.1.0'}) async {
    for (final s in _subs) {
      await s.cancel();
    }
    for (final e in _pending.entries) {
      for (final rows in e.value.values) {
        _flush(e.key, rows);
      }
    }
    for (final s in _sinks.values) {
      await s.flush();
      await s.close();
    }
    final ev = File('${dir.path}/events.csv').openWrite();
    ev.writeln('t_strike_node_us,foot,step_class,confidence,expected_class,timing_err_ms,verdict,label_class,label_source');
    events.sort((a, b) => a.ev.tStrikeNodeUs.compareTo(b.ev.tStrikeNodeUs));
    for (final r in events) {
      final e = r.ev;
      ev.writeln('${e.tStrikeNodeUs},${r.foot == Role.left ? 'L' : 'R'},${e.stepClass.index},${e.confidence},'
          '${e.expectedClass.index},${e.timingErrMs},${e.verdict.index},${r.labelClass},${r.labelSource}');
    }
    await ev.flush();
    await ev.close();

    final meta = {
      'session_id': sessionId,
      'dancer': dancer,
      'preset_id': preset.id,
      'preset_name': preset.name,
      'bpm': preset.bpm,
      'mode': mode.name,
      't0_app_ms': t0AppMs,
      'nodes': {
        for (final n in nodes.nodes.where((n) => n.connected))
          n.roleLabel: {'offset_us': n.offsetUs, 'fw_version': n.status?.fwVersion},
      },
      'app_version': appVersion,
      'protocol_version': protocolVersion,
    };
    await File('${dir.path}/session.json').writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
    debugPrint('session saved: ${dir.path} (${events.length} events)');
  }

  List<File> get files => [
        for (final name in ['session.json', 'L.csv', 'R.csv', 'events.csv'])
          if (File('${dir.path}/$name').existsSync()) File('${dir.path}/$name'),
      ];
}
