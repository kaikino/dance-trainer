import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on while a session runs: a routine is danced without
/// touching the screen, and an iPhone locks after 30 s by default (as a
/// phone or tablet does after its own timeout).
class ScreenAwake {
  static Future<void> on() => _set(true);
  static Future<void> off() => _set(false);

  static Future<void> _set(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('screen awake: $e'); // no plugin (tests, desktop)
    }
  }
}
