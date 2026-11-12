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

  /// The "How to wear" cards have been seen (they open by themselves once).
  static bool onboardingSeen = false;

  /// The routine screen as it was last left: routine id, mode name, and the
  /// tempo per mode name (Practice starts slower).
  static int? lastPresetId;
  static String? lastKind;
  static Map<String, double> tempoByKind = {};

  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

  static Future<void> load() async {
    try {
      final j = jsonDecode(await (await _file()).readAsString()) as Map<String, dynamic>;
      audioDelayMs = j['audio_delay_ms'] as int? ?? audioDelayMs;
      audioDelayMeasured = j['audio_delay_measured'] as bool? ?? false;
      onboardingSeen = j['onboarding_seen'] as bool? ?? false;
      lastPresetId = j['last_preset_id'] as int?;
      lastKind = j['last_kind'] as String?;
      tempoByKind = {
        for (final e in ((j['tempo_by_kind'] as Map<String, dynamic>?) ?? const {}).entries)
          if (e.value is num) e.key: (e.value as num).toDouble(),
      };
    } catch (_) {
      // First run, or an unreadable file: keep the defaults.
    }
  }

  static Future<void> save() async {
    await (await _file()).writeAsString(jsonEncode({
      'audio_delay_ms': audioDelayMs,
      'audio_delay_measured': audioDelayMeasured,
      'onboarding_seen': onboardingSeen,
      'last_preset_id': lastPresetId,
      'last_kind': lastKind,
      'tempo_by_kind': tempoByKind,
    }));
  }
}
