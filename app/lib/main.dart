import 'package:flutter/material.dart';

import 'ble/node_client.dart';
import 'screens/connect_screen.dart';
import 'store/settings.dart';

/// Build with --dart-define=FAKE_NODES=true to run against simulated nodes
/// (emulator, desktop, or a phone with no hardware nearby).
const fakeNodes = bool.fromEnvironment('FAKE_NODES');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.load();
  runApp(DanceTrainerApp(manager: NodeManager(fake: fakeNodes)));
}

class DanceTrainerApp extends StatelessWidget {
  const DanceTrainerApp({super.key, required this.manager});
  final NodeManager manager;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: fakeNodes ? 'Dance Trainer (simulated nodes)' : 'Dance Trainer',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: ConnectScreen(manager: manager),
    );
  }
}
