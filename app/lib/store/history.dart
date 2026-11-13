import 'dart:convert';
import 'dart:io';
import 'dart:math';


import '../models/session_kind.dart';
import '../models/session_score.dart';
import 'app_dirs.dart';

/// One past scored session, read back from the "score" block of its
/// session.json. Capture sessions have no score and are not listed.
class HistoryEntry {
  const HistoryEntry({
    required this.sessionId,
    required this.date,
    required this.presetId,
    required this.presetName,
    required this.kind,
    required this.complete,
    required this.accuracy,
    required this.firstTryAccuracy,
    required this.judged,
    required this.steps,
    required this.bpmMin,
    required this.bpmMax,
  });

  final String sessionId;
  final DateTime date;
  final int presetId;
  final String presetName;
  final SessionKind kind;

  /// Danced from beat 1 to the end. A run ended early (or a drill from a
  /// later bar) is listed as incomplete and never counts as a best.
  final bool complete;
  final double? accuracy, firstTryAccuracy;
  final int judged, steps;
  final double bpmMin, bpmMax;

  /// The number the dancer is shown: right first time in Practice (retries
  /// would flatter it), plain accuracy in Performance.
  double? get headline => kind == SessionKind.practice ? firstTryAccuracy : accuracy;

  /// The "score" block written into session.json at the end of a session.
  static Map<String, Object?> summarize(
    SessionScore score, {
    required SessionKind kind,
    required bool complete,
    required List<double> bpms,
  }) =>
      {
        'kind': kind.name,
        'complete': complete,
        'judged': score.judged,
        'steps': score.preset.steps.length,
        'accuracy': score.accuracy,
        'first_try_accuracy': score.firstTryAccuracy,
        'bpm_min': bpms.isEmpty ? score.preset.bpm : bpms.reduce(min),
        'bpm_max': bpms.isEmpty ? score.preset.bpm : bpms.reduce(max),
        'ended_at_ms': DateTime.now().millisecondsSinceEpoch,
      };

  /// From a whole session.json, or null when it has no usable score.
  static HistoryEntry? fromSession(Map<String, dynamic> j) {
    final s = j['score'];
    if (s is! Map<String, dynamic>) return null;
    final kind = SessionKind.values.where((k) => k.name == s['kind']).firstOrNull;
    if (kind == null || kind == SessionKind.capture) return null;
    final whenMs = (s['ended_at_ms'] as num?) ?? (j['t0_app_ms'] as num?);
    double? d(Object? v) => (v as num?)?.toDouble();
    return HistoryEntry(
      sessionId: j['session_id'] as String? ?? '',
      date: DateTime.fromMillisecondsSinceEpoch(whenMs?.toInt() ?? 0),
      presetId: (j['preset_id'] as num?)?.toInt() ?? -1,
      presetName: j['preset_name'] as String? ?? '',
      kind: kind,
      complete: s['complete'] == true,
      accuracy: d(s['accuracy']),
      firstTryAccuracy: d(s['first_try_accuracy']),
      judged: (s['judged'] as num?)?.toInt() ?? 0,
      steps: (s['steps'] as num?)?.toInt() ?? 0,
      bpmMin: d(s['bpm_min']) ?? 0,
      bpmMax: d(s['bpm_max']) ?? 0,
    );
  }
}

/// Past sessions from the app's documents folder (sessions/<id>/session.json).
class SessionHistory {
  static Future<List<HistoryEntry>> load({int? presetId}) async {
    final dir = Directory('${(await AppDirs.private()).path}/sessions');
    if (!await dir.exists()) return [];
    final out = <HistoryEntry>[];
    await for (final d in dir.list()) {
      if (d is! Directory) continue;
      try {
        final f = File('${d.path}/session.json');
        if (!await f.exists()) continue;
        final e = HistoryEntry.fromSession(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
        if (e != null && (presetId == null || e.presetId == presetId)) out.add(e);
      } catch (_) {
        // A half-written or foreign file: skip it.
      }
    }
    return out..sort((a, b) => b.date.compareTo(a.date));
  }

  /// Best headline score over complete runs, or null if there is none.
  static double? best(Iterable<HistoryEntry> entries) => entries
      .where((e) => e.complete && e.headline != null)
      .map((e) => e.headline!)
      .fold<double?>(null, (a, b) => a == null || b > a ? b : a);

  /// Best per routine id, complete runs only.
  static Map<int, double> bestByPreset(Iterable<HistoryEntry> entries) {
    final out = <int, double>{};
    for (final e in entries) {
      final h = e.headline;
      if (!e.complete || h == null) continue;
      if (h > (out[e.presetId] ?? -1)) out[e.presetId] = h;
    }
    return out;
  }

  /// The latest complete run of the same routine and kind before [sessionId]
  /// (entries newest first, as [load] returns them).
  static HistoryEntry? previous(List<HistoryEntry> entries,
      {required int presetId, required SessionKind kind, required String sessionId}) {
    final i = entries.indexWhere((e) => e.sessionId == sessionId);
    return entries
        .skip(i < 0 ? 0 : i + 1)
        .where((e) => e.presetId == presetId && e.kind == kind && e.complete && e.headline != null)
        .firstOrNull;
  }
}
