import 'dart:io';

import 'package:flutter/foundation.dart';

import 'session_store.dart';

/// A sitting of recording for training: every run recorded while it is open
/// is saved to its own folder, Documents/DanceTrainer/<id>/<run>. A new one
/// starts each time the routine screen enters Capture (recording) mode.
class TrainingSession {
  TrainingSession._(this.id, this.dir);

  final String id;
  final Directory dir;

  /// The open training session, if recording mode is on.
  static final current = ValueNotifier<TrainingSession?>(null);

  /// Opens a new training session (the folder is made on the first save).
  static Future<TrainingSession> start(String dancer) async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final id = 'training-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}'
        '${two(now.second)}-${_safe(dancer)}';
    final root = await SessionRecorder.sharedRoot();
    return current.value = TrainingSession._(id, Directory('$root/$id'));
  }

  static void close() => current.value = null;

  /// Runs saved so far.
  int get runs {
    try {
      return dir.existsSync() ? dir.listSync().whereType<Directory>().length : 0;
    } catch (_) {
      return 0;
    }
  }

  static String _safe(String s) {
    final t = s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    return t.isEmpty ? 'dancer' : t;
  }
}
