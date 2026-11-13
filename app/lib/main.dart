import 'package:flutter/material.dart';

import 'ble/node_client.dart';
import 'screens/connect_screen.dart';
import 'store/settings.dart';
import 'ui/tokens.dart';

/// Build with --dart-define=FAKE_NODES=true to run against simulated nodes
/// (emulator, desktop, or a phone with no hardware nearby).
const fakeNodes = bool.fromEnvironment('FAKE_NODES');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.load();
  runApp(DanceTrainerApp(manager: NodeManager(fake: fakeNodes)));
}

class DanceTrainerApp extends StatelessWidget {
  const DanceTrainerApp({super.key, required this.manager, this.home});
  final NodeManager manager;

  /// The first screen; the home screen unless a test shows another one in
  /// the app's shell (theme, safe areas).
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: fakeNodes ? 'Dance Trainer (simulated nodes)' : 'Dance Trainer',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      // Android 15 draws apps edge to edge; keep every screen's bottom buttons
      // clear of the navigation bar (the app bars already handle the top).
      // On a tablet the app bar title is centred over the centred content.
      builder: (context, child) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(appBarTheme: theme.appBarTheme.copyWith(centerTitle: Space.isTablet(context))),
          child: SafeArea(top: false, child: child!),
        );
      },
      home: home ?? ConnectScreen(manager: manager),
    );
  }

  /// Calm Material 3 built from ui/tokens.dart: flat tinted cards, rounded
  /// buttons with larger labels so they read from a couple of metres on a
  /// tablet, and one type scale.
  static ThemeData _theme(Brightness brightness) {
    final base = ThemeData(colorSchemeSeed: Colors.indigo, brightness: brightness, useMaterial3: true);
    final text = AppType.apply(base.textTheme);
    final label = AppType.button(text);
    const rounded = RoundedRectangleBorder(borderRadius: Radii.mdAll);
    return base.copyWith(
      textTheme: text,
      // ThemeData's text theme carries no sizes until Theme.of merges in the
      // typography; the app bar style is used as is, so it gets them here.
      appBarTheme: AppBarTheme(
          titleTextStyle: base.typography.englishLike.titleLarge!
              .merge(text.titleLarge)
              .copyWith(color: base.colorScheme.onSurface)),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(textStyle: label, shape: rounded)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(textStyle: label, shape: rounded)),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(textStyle: label)),
      segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(textStyle: label)),
      cardTheme: CardThemeData(elevation: Elevation.card, color: base.colorScheme.surfaceContainer, shape: rounded),
      dialogTheme: const DialogThemeData(shape: RoundedRectangleBorder(borderRadius: Radii.lgAll)),
    );
  }
}
