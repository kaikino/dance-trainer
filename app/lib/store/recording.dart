import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ble/protocol.dart';
import 'session_store.dart';

/// One foot's raw stream from L.csv / R.csv (docs/data-format.md), on a time
/// axis in seconds from the start of the recording.
class FootSeries {
  FootSeries(this.t, this.acc, this.gyr, this.pitch, this.roll, {required this.rateHz, required this.gaps});

  final Float64List t; // s
  final List<Float32List> acc; // x, y, z in g
  final List<Float32List>? gyr; // x, y, z in dps; null in dance mode
  final Float32List pitch, roll; // deg, from the node's orientation
  final double rateHz; // measured
  final int gaps; // dropouts longer than 3 sample periods

  int get length => t.length;
  double get seconds => t.isEmpty ? 0 : t.last - t.first;

  late final Float32List accMag = Float32List.fromList([
    for (var i = 0; i < length; i++) sqrt(acc[0][i] * acc[0][i] + acc[1][i] * acc[1][i] + acc[2][i] * acc[2][i]),
  ]);
}

/// A strike the node reported (events.csv).
class StrikeMark {
  const StrikeMark(this.t, this.foot, this.cls, this.conf, this.expected, this.verdict, this.label);
  final double t; // s from the start
  final Role foot;
  final StepClass cls;
  final int conf;
  final StepClass expected;
  final Verdict verdict;
  final int label; // training label class, -1 unusable
}

/// A recorded run read back from its folder.
class Recording {
  Recording._(this.dir, this.meta, this.feet, this.strikes, this.beats, this.t0AppMs, this.duration);

  final Directory dir;
  final Map<String, dynamic> meta;
  final Map<Role, FootSeries> feet;
  final List<StrikeMark> strikes;
  final List<double> beats; // s from the start
  final double t0AppMs; // app time of t = 0
  final double duration; // s

  String get id => meta['session_id'] as String? ?? dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  String get presetName => meta['preset_name'] as String? ?? 'Routine';
  String get dancer => meta['dancer'] as String? ?? '';
  String get mode => meta['mode'] as String? ?? '';
  bool get capture => mode == 'capture';

  static Future<Recording> load(Directory dir) => compute(_load, dir.path);

  static Recording _load(String path) {
    final dir = Directory(path);
    Map<String, dynamic> meta = {};
    final sj = File('$path/session.json');
    if (sj.existsSync()) meta = jsonDecode(sj.readAsStringSync()) as Map<String, dynamic>;
    final capture = meta['mode'] == 'capture';

    // Raw rows first, to find the common start.
    final raw = <Role, List<List<double>>>{};
    for (final f in Role.values) {
      final file = File('$path/${f == Role.left ? 'L' : 'R'}.csv');
      if (!file.existsSync()) continue;
      raw[f] = _rows(file.readAsLinesSync());
    }
    final events = File('$path/events.csv').existsSync() ? _eventRows(File('$path/events.csv').readAsLinesSync()) : <List<String>>[];

    var t0 = double.infinity, tEnd = double.negativeInfinity;
    for (final rows in raw.values) {
      if (rows.isEmpty) continue;
      t0 = min(t0, rows.first[_tApp]);
      tEnd = max(tEnd, rows.last[_tApp]);
    }
    if (!t0.isFinite) {
      t0 = (meta['t0_app_ms'] as num?)?.toDouble() ?? 0;
      tEnd = t0;
    }

    final feet = <Role, FootSeries>{};
    for (final MapEntry(key: f, value: rows) in raw.entries) {
      if (rows.isEmpty) continue;
      feet[f] = _series(rows, t0, capture);
    }

    final strikes = <StrikeMark>[];
    for (final e in events) {
      final t = double.tryParse(e.length > 9 ? e[9] : '');
      if (t == null) continue;
      StepClass cls(String s) {
        final i = int.tryParse(s) ?? 0;
        return i >= 0 && i < StepClass.values.length ? StepClass.values[i] : StepClass.none;
      }

      final v = int.tryParse(e[6]) ?? 0;
      strikes.add(StrikeMark((t - t0) / 1000, e[1] == 'R' ? Role.right : Role.left, cls(e[2]), int.tryParse(e[3]) ?? 0,
          cls(e[4]), v >= 0 && v < Verdict.values.length ? Verdict.values[v] : Verdict.unjudged, int.tryParse(e[7]) ?? -1));
    }
    tEnd = max(tEnd, t0 + (strikes.isEmpty ? 0 : strikes.map((s) => s.t).reduce(max) * 1000));

    // The beat grid from the segments (docs/data-format.md).
    final beats = <double>[];
    final segs = (meta['segments'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    for (var k = 0; k < segs.length; k++) {
      final s = segs[k];
      final st0 = (s['t0_app_ms'] as num).toDouble(), bpm = (s['bpm'] as num).toDouble();
      final from = (s['from_beat'] as num).toDouble();
      final until = k + 1 < segs.length ? (segs[k + 1]['t0_app_ms'] as num).toDouble() : tEnd;
      for (var b = from; ; b += 1) {
        final t = st0 + (b - 1) * 60000 / bpm;
        if (t > until || t > tEnd) break;
        if (t >= t0) beats.add((t - t0) / 1000);
      }
    }
    return Recording._(dir, meta, feet, strikes..sort((a, b) => a.t.compareTo(b.t)), beats, t0, (tEnd - t0) / 1000);
  }

  // t_node_us,ax,ay,az,gx,gy,gz,qw,qx,qy,qz,t_app_ms
  static const _tApp = 11;

  static List<List<double>> _rows(List<String> lines) {
    final out = <List<double>>[];
    for (var i = 1; i < lines.length; i++) {
      final c = lines[i].split(',');
      if (c.length < 12) continue;
      final t = double.tryParse(c[_tApp]);
      if (t == null) continue;
      out.add([for (var k = 0; k < 12; k++) double.tryParse(c[k]) ?? double.nan]);
    }
    out.sort((a, b) => a[_tApp].compareTo(b[_tApp]));
    return out;
  }

  static List<List<String>> _eventRows(List<String> lines) =>
      [for (var i = 1; i < lines.length; i++) if (lines[i].trim().isNotEmpty) lines[i].split(',')];

  static FootSeries _series(List<List<double>> rows, double t0, bool capture) {
    final n = rows.length;
    final t = Float64List(n);
    final acc = List.generate(3, (_) => Float32List(n));
    final gyr = List.generate(3, (_) => Float32List(n));
    final pitch = Float32List(n), roll = Float32List(n);
    var hasGyro = false;
    for (var i = 0; i < n; i++) {
      final r = rows[i];
      t[i] = (r[_tApp] - t0) / 1000;
      for (var k = 0; k < 3; k++) {
        acc[k][i] = r[1 + k] / 1000; // mg -> g
        final g = r[4 + k];
        if (!g.isNaN) hasGyro = true;
        gyr[k][i] = g.isNaN ? 0 : g / 10; // dps x10 -> dps
      }
      final w = r[7] / 16384, x = r[8] / 16384, y = r[9] / 16384, z = r[10] / 16384;
      roll[i] = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * 180 / pi;
      pitch[i] = asin((2 * (w * y - z * x)).clamp(-1.0, 1.0)) * 180 / pi;
    }
    final nominal = capture ? 1 / 104 : 1 / 52;
    var gaps = 0;
    for (var i = 1; i < n; i++) {
      if (t[i] - t[i - 1] > 3 * nominal) gaps++;
    }
    final rate = n > 1 && t[n - 1] > t[0] ? (n - 1) / (t[n - 1] - t[0]) : 0.0;
    return FootSeries(t, acc, hasGyro ? gyr : null, pitch, roll, rateHz: rate, gaps: gaps);
  }
}

/// A folder of saved runs on shared storage: a training session, or the
/// manually saved runs.
class RecordingFolder {
  RecordingFolder(this.dir, this.title, this.subtitle, this.when, this.runs, {required this.training});
  final Directory dir;
  final String title, subtitle;
  final DateTime? when;
  final List<RunInfo> runs;
  final bool training;
}

class RunInfo {
  RunInfo(this.dir, this.id, this.preset, this.when, this.steps, this.bytes, this.mode);
  final Directory dir;
  final String id, preset, mode;
  final DateTime? when;
  final int steps, bytes;
}

/// Everything under Documents/DanceTrainer, newest first.
class RecordingIndex {
  static Future<List<RecordingFolder>> load() async {
    final root = Directory(await SessionRecorder.sharedRoot());
    if (!await root.exists()) return [];
    final folders = <RecordingFolder>[];
    final loose = <RunInfo>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final name = _name(d);
      if (File('${d.path}/session.json').existsSync()) {
        loose.add(_run(d)); // saved before training sessions existed
        continue;
      }
      final runs = [for (final r in d.listSync().whereType<Directory>()) _run(r)]
        ..sort((a, b) => (b.when ?? DateTime(0)).compareTo(a.when ?? DateTime(0)));
      final training = name.startsWith('training-');
      final when = training ? parseStamp(name.substring(9)) : (runs.isEmpty ? null : runs.first.when);
      final dancer = training ? name.split('-').skip(3).join('-') : '';
      folders.add(RecordingFolder(
        d,
        training ? 'Training session${when == null ? '' : ' · ${formatWhen(when)}'}' : 'Saved runs',
        training ? (dancer.isEmpty ? name : 'Dancer: $dancer') : 'Performance and practice runs you saved',
        when,
        runs,
        training: training,
      ));
    }
    if (loose.isNotEmpty) {
      folders.add(RecordingFolder(root, 'Older saved runs', 'Saved before training sessions', null, loose,
          training: false));
    }
    folders.sort((a, b) => (b.when ?? DateTime(0)).compareTo(a.when ?? DateTime(0)));
    return folders;
  }

  static String _name(Directory d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last;

  static RunInfo _run(Directory d) {
    var preset = 'Run', mode = '';
    var steps = 0, bytes = 0;
    try {
      final m = jsonDecode(File('${d.path}/session.json').readAsStringSync()) as Map<String, dynamic>;
      preset = m['preset_name'] as String? ?? preset;
      mode = m['mode'] as String? ?? '';
    } catch (_) {}
    try {
      for (final f in d.listSync().whereType<File>()) {
        bytes += f.lengthSync();
        if (f.path.endsWith('events.csv')) steps = max(0, f.readAsLinesSync().length - 1);
      }
    } catch (_) {}
    final id = _name(d);
    return RunInfo(d, id, preset, parseStamp(id), steps, bytes, mode);
  }

  /// "YYYYMMDD-HHMMSS…" at the start of [s].
  static DateTime? parseStamp(String s) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})').firstMatch(s);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  }

  static String formatWhen(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} ${d.year}, ${two(d.hour)}:${two(d.minute)}';
  }
}
