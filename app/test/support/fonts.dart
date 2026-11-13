import 'dart:io';

import 'package:flutter/services.dart';

/// Loads Roboto (from the Flutter SDK) under the Material and Apple system
/// font names, so widget tests measure real text instead of the test font's
/// square glyphs. Without the SDK fonts the tests fall back to the test font
/// (wider, so stricter).
Future<void> loadRealFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;
  final weights = [
    for (final w in ['Regular', 'Medium', 'Bold', 'Black', 'Light'])
      if (File('${dir.path}/Roboto-$w.ttf').existsSync()) File('${dir.path}/Roboto-$w.ttf').readAsBytesSync(),
  ];
  for (final family in [
    'Roboto',
    '.SF Pro Text',
    '.SF Pro Display',
    '.SF UI Text',
    '.SF UI Display',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
  ]) {
    final l = FontLoader(family);
    for (final b in weights) {
      l.addFont(Future.value(ByteData.view(b.buffer)));
    }
    await l.load();
  }
  final icons = File('${dir.path}/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(icons.readAsBytesSync().buffer)))).load();
  }
}
