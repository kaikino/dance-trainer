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
      theme: _theme(),
      // Android 15 draws apps edge to edge; keep every screen's bottom buttons
      // clear of the navigation bar (the app bars already handle the top).
      builder: (context, child) => SafeArea(top: false, child: child!),
      home: ConnectScreen(manager: manager),
    );
  }

  /// Calm Material 3: flat tinted cards, rounded buttons with larger labels so
  /// they read from a couple of metres on a tablet.
  static ThemeData _theme() {
    final base = ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true);
    const label = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(textStyle: label, shape: rounded)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(textStyle: label, shape: rounded)),
      cardTheme: CardThemeData(elevation: 0, color: base.colorScheme.surfaceContainer, shape: rounded),
    );
  }
}
