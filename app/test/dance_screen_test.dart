import 'package:dance_trainer/ble/fake_node.dart';
import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/screens/dance_screen.dart';
import 'package:dance_trainer/screens/preset_screen.dart';
import 'package:dance_trainer/screens/summary_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

Preset _loop() => Preset.fromJson({
      'id': 77,
      'name': 'Loop',
      'bpm': 120,
      'loop': true,
      'repeats': 8,
      'steps': [
        {'beat': 1.0, 'foot': 'L', 'class': 'forward'},
        {'beat': 2.0, 'foot': 'R', 'class': 'in_place'},
        {'beat': 3.0, 'foot': 'L', 'class': 'back'},
        {'beat': 4.0, 'foot': 'R', 'class': 'in_place'},
      ],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = FakeDocuments();
  installFakeAudio();

  test('disconnect banner names every missing node', () {
    expect(disconnectedText({}), isNull);
    expect(disconnectedText({Role.right}), 'Right ankle disconnected');
    expect(disconnectedText({Role.left, Role.right}), 'Both ankles disconnected');
  });

  test('summary tempo shows the slow-down as a range', () {
    expect(tempoLabel([], fallback: 96), '96 bpm');
    expect(tempoLabel([96, 96], fallback: 96), '96 bpm');
    expect(tempoLabel([96, 96, 76.8], fallback: 76.8), '96 → 77 bpm');
    expect(tempoLabel([96, 76.8, 61.4], fallback: 61.4), '96 → 61 bpm');
  });

  testWidgets('the banner stays while any node is missing; Reconnect brings it back', (tester) async {
    final m = NodeManager(fake: true);
    for (final n in m.nodes) {
      (n as FakeNodeClient)
        ..pMissed = 0
        ..pWrong = 0
        ..pLate = 0;
    }
    await tester.runAsync(m.scanAndConnect);
    await tester.pumpWidget(MaterialApp(
        home: DanceScreen(manager: m, preset: _loop(), kind: SessionKind.performance, dancer: 't')));

    // Real time passes for the fake nodes and the clock; frames for the screen.
    Future<void> run(int ms) async {
      for (var t = 0; t < ms; t += 50) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await run(2500); // synced, scheduled, started
    expect(find.textContaining('disconnected'), findsNothing);

    await tester.runAsync(() async {
      await m.left.disconnect();
      await m.right.disconnect();
    });
    await run(100);
    expect(find.text('Both ankles disconnected'), findsOneWidget);

    await tester.runAsync((m.left as FakeNodeClient).connect);
    await run(500);
    expect(find.text('Right ankle disconnected'), findsOneWidget);
    expect(find.text('Left ankle reconnected'), findsOneWidget);

    await run(3500); // the good news fades; the missing node does not
    expect(find.text('Left ankle reconnected'), findsNothing);
    expect(find.text('Right ankle disconnected'), findsOneWidget);

    await tester.tap(find.text('Reconnect'));
    await run(1500);
    expect(m.right.connected, isTrue);
    expect(find.textContaining('disconnected'), findsNothing);
    expect(find.text('Right ankle reconnected'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await run(300);
    for (final n in m.nodes) {
      await tester.runAsync(n.disconnect);
    }
  });
}
