import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Per-device settings, kept in `settings.json` in the app's documents folder.
class AppSettings {
  /// Time from asking the player to start to the sound leaving the speaker,
  /// in ms. Every device differs (often 100–300 ms on Android), so the chart
  /// and the nodes' t0 are shifted by this. Measured with the tap test.
  static int audioDelayMs = 150;
  static bool audioDelayMeasured = false;

  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

  static Future<void> load() async {
    try {
      final j = jsonDecode(await (await _file()).readAsString()) as Map<String, dynamic>;
      audioDelayMs = j['audio_delay_ms'] as int? ?? audioDelayMs;
      audioDelayMeasured = j['audio_delay_measured'] as bool? ?? false;
    } catch (_) {
      // First run, or an unreadable file: keep the defaults.
    }
  }

  static Future<void> save() async {
    await (await _file()).writeAsString(jsonEncode({
      'audio_delay_ms': audioDelayMs,
      'audio_delay_measured': audioDelayMeasured,
    }));
  }
}
