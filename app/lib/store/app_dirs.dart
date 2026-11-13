import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Where the app keeps things, per platform.
///
///   private  every run as it is recorded, history, settings. Android: the
///            app's documents folder (as always, so existing data stays put).
///            iOS: Application Support, which the Files app does not show.
///   shared   the runs the user keeps (Save, training sessions), reachable
///            outside the app. Android: Documents/DanceTrainer on shared
///            storage (Files app, USB; survives reinstalling). iOS: the app's
///            Documents folder/DanceTrainer, which Info.plist's
///            UIFileSharingEnabled shows in Files › On My iPhone › Dance
///            Trainer (and Finder over USB); removed with the app.
class AppDirs {
  static bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

  static Future<Directory> private() async {
    final d = _ios ? await getApplicationSupportDirectory() : await getApplicationDocumentsDirectory();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<String> shared() async {
    if (_ios) return '${(await getApplicationDocumentsDirectory()).path}/DanceTrainer';
    // Android 11+ lets an app create files in Documents without a permission.
    final ext = await getExternalStorageDirectory(); // .../Android/data/<pkg>/files
    final i = ext?.path.indexOf('/Android/') ?? -1;
    final root = i > 0 ? ext!.path.substring(0, i) : '/storage/emulated/0';
    return '$root/Documents/DanceTrainer';
  }

  /// How to find [shared] on this device, for the screens that mention it.
  static String get sharedLabel => _ios ? 'Files › On My iPhone › Dance Trainer › DanceTrainer' : 'Documents/DanceTrainer';

  /// A path under [shared] as the user sees it: "Documents/DanceTrainer/x" on
  /// Android, "Files › … › DanceTrainer/x" on iOS.
  static String describe(String path) {
    final i = path.indexOf('/DanceTrainer');
    if (i < 0) return path;
    return '$sharedLabel${path.substring(i + '/DanceTrainer'.length)}';
  }

  /// "this tablet", "this iPhone": for messages about deleting and saving.
  /// [screen] tells a phone from a tablet.
  static String deviceName(Size screen) {
    final tablet = screen.shortestSide >= 600;
    if (_ios) return tablet ? 'this iPad' : 'this iPhone';
    return tablet ? 'this tablet' : 'this phone';
  }
}
