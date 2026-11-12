import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ble/clock_sync.dart';
import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';

/// One recorded step, as written to events.csv (docs/data-format.md).
class RecordedEvent {
  final Role foot;
  final StepEvent ev;

  /// Strike time on the app clock (ms since epoch, wrap-safe); null if the
  /// node was not synced yet.
  final double? tAppMs;
  int labelClass;
  String labelSource;
  RecordedEvent(this.foot, this.ev, this.tAppMs, this.labelClass, this.labelSource);
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

  /// Wall-clock time of beat 1 for the first segment.
  int? get t0AppMs => segments.isEmpty ? null : segments.first.t0AppMs;

  /// One entry per start of the nodes: a practice rewind (or a slow-down, or
  /// a resume after a pause) adds a segment that restarts at [fromBeat] with
  /// its own t0 and tempo.
  final segments = <({double fromBeat, int t0AppMs, double bpm})>[];
  void addSegment(int t0AppMs, {double fromBeat = 1, double? bpm}) =>
      segments.add((fromBeat: fromBeat, t0AppMs: t0AppMs, bpm: bpm ?? preset.bpm));

  /// Per node: clock offset and firmware, noted after each clock sync so the
  /// metadata survives the node dropping out before the end.
  final _nodeMeta = <Role, Map<String, Object?>>{};

  /// Every clock sync, in order: a node that reconnects (and maybe rebooted)
  /// gets a new offset, and the earlier rows were timed with the old one.
  final _syncs = <Map<String, Object?>>[];

  void noteNode(NodeClient n) {
    final meta = {'offset_us': n.offsetUs, 'fw_version': n.status?.fwVersion};
    _nodeMeta[n.role] = meta;
    final last = _syncs.lastWhere((s) => s['foot'] == n.roleLabel, orElse: () => const {});
    if (n.offsetUs == null || last['offset_us'] == n.offsetUs) return;
    _syncs.add({'foot': n.roleLabel, ...meta, 'synced_at_app_ms': DateTime.now().millisecondsSinceEpoch});
  }

  /// Stream samples written per node, for the capture screen.
  final sampleCounts = <Role, int>{};

  bool _begun = false, _ended = false;
  bool get begun => _begun;
  final events = <RecordedEvent>[];
  final _subs = <StreamSubscription<dynamic>>[];
  final _sinks = <Role, IOSink>{};

  // Capture mode sends an accel batch and a gyro batch with the same t0; the
  // first half waits here for the second.
  final _pending = <Role, Map<int, StreamBatch>>{};

  /// Spacing of the samples in a batch, µs.
  double get sampleUs => StreamBatch.sampleUs(mode);

  Future<void> begin() async {
    _begun = true;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    sessionId =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}-$dancer';
    final docs = await getApplicationDocumentsDirectory();
    dir = Directory('${docs.path}/sessions/$sessionId');
    await dir.create(recursive: true);

    // Every node, connected or not: one that joins or comes back mid-session
    // is recorded too (its file is opened on its first batch).
    for (final n in nodes.nodes) {
      _subs.add(n.batches.listen((b) => _onBatch(n, b)));
      _subs.add(n.events.listen((e) => _onEvent(n, e)));
    }
  }

  /// App time (ms since epoch) of node time [tNodeUs], or null before the
  /// node's clock is synced. Resolved against now, so the node's clock wrap
  /// and a reconnect (new offset) are both handled.
  static double? _appMs(NodeClient n, int tNodeUs) {
    final offset = n.offsetUs;
    if (offset == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    return now + nodeMsAfter(tNodeUs, now, offset);
  }

  void _onBatch(NodeClient n, StreamBatch b) {
    if (mode != Mode.capture) {
      if (!b.samples.first.isGyro) _write(n, b, null);
      return;
    }
    // Capture: rows need both halves. A half with no partner (an idle-mode
    // accel batch before Start or after Stop, or a lost notification) is
    // dropped, never written with empty columns.
    final pend = _pending.putIfAbsent(n.role, () => {});
    final other = pend.remove(b.t0NodeUs);
    if (other != null && other.samples.first.isGyro != b.samples.first.isGyro) {
      final (acc, gyr) = b.samples.first.isGyro ? (other, b) : (b, other);
      _write(n, acc, gyr);
    } else {
      pend[b.t0NodeUs] = b;
    }
    pend.removeWhere((t0, _) => u32DeltaUs(b.t0NodeUs, t0) > 1000000);
  }

  /// Writes one batch as rows; [gyr] is null outside capture. Rows from a
  /// node whose clock is not synced yet (just reconnected) are skipped:
  /// they could not be placed on the session's timeline.
  void _write(NodeClient n, StreamBatch acc, StreamBatch? gyr) {
    final appT0 = _appMs(n, acc.t0NodeUs);
    if (appT0 == null) return;
    final sink = _sinks.putIfAbsent(n.role, () {
      final sink = File('${dir.path}/${n.roleLabel}.csv').openWrite();
      sink.writeln('t_node_us,ax,ay,az,gx,gy,gz,qw,qx,qy,qz,t_app_ms');
      return sink;
    });
    int q(double v) => (v * 16384).round();
    for (var i = 0; i < acc.samples.length; i++) {
      final dtUs = (i * sampleUs).round();
      final a = acc.samples[i];
      final g = gyr?.samples[i];
      sink.writeln([
        (acc.t0NodeUs + dtUs) & 0xffffffff,
        a.ax, a.ay, a.az,
        ...g == null ? ['', '', ''] : [g.ax, g.ay, g.az],
        q(a.qw), q(a.qx), q(a.qy), q(a.qz),
        (appT0 + dtUs / 1000).toStringAsFixed(1),
      ].join(','));
    }
    sampleCounts.update(n.role, (c) => c + acc.samples.length, ifAbsent: () => acc.samples.length);
  }

  void _onEvent(NodeClient n, StepEvent e) {
    final role = n.role;
    var label = -1;
    var source = '';
    final tAppMs = _appMs(n, e.tStrikeNodeUs);
    // Against the current segment: a resume after a pause restarts the clock.
    final seg = segments.lastOrNull;
    if (mode == Mode.capture && seg != null && tAppMs != null) {
      // Label from the schedule: nearest scheduled beat for this foot within 250 ms.
      final beatMs = 60000 / seg.bpm;
      final i = preset.nearestStep(role, 1 + (tAppMs - seg.t0AppMs) / beatMs, within: 250 / beatMs);
      if (i != null) {
        label = preset.steps[i].stepClass.index;
        source = 'capture';
      }
    }
    events.add(RecordedEvent(role, e, tAppMs, label, source));
  }

  /// Writes events.csv and session.json. Safe to call twice; a no-op before [begin].
  /// [score] (a scored session's summary, see SessionSummary) is written
  /// under "score" for the History screen; capture sessions have none.
  Future<void> end({String appVersion = '0.1.0', Map<String, Object?>? score}) async {
    if (!_begun || _ended) return;
    _ended = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _pending.clear(); // halves whose partner never came
    for (final s in _sinks.values) {
      await s.flush();
      await s.close();
    }
    final ev = File('${dir.path}/events.csv').openWrite();
    ev.writeln('t_strike_node_us,foot,step_class,confidence,expected_class,timing_err_ms,verdict,label_class,'
        'label_source,t_app_ms');
    // By app time, not the raw node clock, which wraps every 71.6 min.
    events.sort((a, b) => (a.tAppMs ?? 0).compareTo(b.tAppMs ?? 0));
    for (final r in events) {
      final e = r.ev;
      ev.writeln('${e.tStrikeNodeUs},${r.foot == Role.left ? 'L' : 'R'},${e.stepClass.index},${e.confidence},'
          '${e.expectedClass.index},${e.timingErrMs},${e.verdict.index},${r.labelClass},${r.labelSource},'
          '${r.tAppMs?.toStringAsFixed(1) ?? ''}');
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
      'segments': [
        for (final g in segments) {'from_beat': g.fromBeat, 't0_app_ms': g.t0AppMs, 'bpm': g.bpm},
      ],
      // The last offset per node; clock_syncs lists every one (a reconnect adds one).
      'nodes': {
        for (final n in nodes.nodes)
          if (n.connected) n.roleLabel: {'offset_us': n.offsetUs, 'fw_version': n.status?.fwVersion}
          else if (_nodeMeta[n.role] case final meta?) n.roleLabel: meta,
      },
      'clock_syncs': _syncs,
      'app_version': appVersion,
      'protocol_version': protocolVersion,
      if (score != null) 'score': score,
    };
    await File('${dir.path}/session.json').writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
    debugPrint('session saved: ${dir.path} (${events.length} events)');
  }

  List<File> get files => [
        for (final name in ['session.json', 'L.csv', 'R.csv', 'events.csv'])
          if (File('${dir.path}/$name').existsSync()) File('${dir.path}/$name'),
      ];
}
