import 'dart:convert';
import 'dart:io';

import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/screens/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

void main() {
  late FakeDocuments docs;
  setUp(() {
    docs = FakeDocuments();
    PathProviderPlatform.instance = docs;
  });

  void session(String id, int day, {bool complete = true, double acc = 0.7}) {
    final dir = Directory('${docs.root.path}/sessions/$id')..createSync(recursive: true);
    File('${dir.path}/session.json').writeAsStringSync(jsonEncode({
      'session_id': id,
      'preset_id': 1,
      'preset_name': 'R',
      't0_app_ms': DateTime(2026, 11, day).millisecondsSinceEpoch,
      'score': {
        'kind': 'performance',
        'complete': complete,
        'judged': 10,
        'steps': 12,
        'accuracy': acc,
        'first_try_accuracy': acc,
        'bpm_min': 96,
        'bpm_max': 96,
        'ended_at_ms': DateTime(2026, 11, day).millisecondsSinceEpoch,
      },
    }));
  }

  const preset = Preset(1, 'R', 96, 4, [PresetStep(1, Role.left, StepClass.forward)]);

  for (final (name, size, runs) in [
    ('phone, one run', const Size(412, 915), 1),
    ('phone, many runs', const Size(412, 915), 14),
    ('tablet', const Size(1280, 800), 5),
  ]) {
    testWidgets('history lays out: $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (var i = 0; i < runs; i++) {
        session('s$i', 1 + i, complete: i.isEven, acc: 0.5 + i / 40);
      }
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: HistoryScreen(preset: preset)));
        // Let the history load from disk.
        for (var k = 0; k < 20 && find.text('Latest').evaluate().isEmpty; k++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(tester.takeException(), isNull);
      expect(find.text('Latest'), findsOneWidget);
      expect(find.text('Older'), runs > 1 ? findsOneWidget : findsNothing);
    });
  }
}
