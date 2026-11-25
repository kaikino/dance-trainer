import 'package:flutter/material.dart';

import 'ble/node_client.dart';
import 'screens/connect_screen.dart';
import 'store/settings.dart';
import 'ui/route_observer.dart';
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
      debugShowCheckedModeBanner: false,
      navigatorObservers: [appRouteObserver],
      // One look everywhere: the dark stage (ui/tokens.dart, Stage).
      theme: _theme(),
      themeMode: ThemeMode.dark,
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

  /// One dark theme, built from ui/tokens.dart: warm charcoal surfaces with
  /// no tint, the tape colour for actions and scores, Oswald headings over
  /// Work Sans, flat panels and small corners.
  static ThemeData _theme() {
    final scheme = ColorScheme.fromSeed(seedColor: Stage.tape, brightness: Brightness.dark).copyWith(
      primary: Stage.tape,
      onPrimary: Stage.onTape,
      primaryContainer: const Color(0xFF2E3313),
      onPrimaryContainer: const Color(0xFFE9F7B0),
      secondary: Stage.muted,
      onSecondary: Stage.onTape,
      secondaryContainer: Stage.panelHigh,
      onSecondaryContainer: Stage.ink,
      tertiary: Stage.pink,
      onTertiary: Stage.onTape,
      tertiaryContainer: const Color(0xFF3A1E2C),
      onTertiaryContainer: const Color(0xFFFFD8E8),
      surface: Stage.bg,
      onSurface: Stage.ink,
      onSurfaceVariant: Stage.muted,
      surfaceContainerLowest: Stage.night,
      surfaceContainerLow: const Color(0xFF181715),
      surfaceContainer: Stage.panel,
      surfaceContainerHigh: Stage.panelHigh,
      surfaceContainerHighest: const Color(0xFF302E2B),
      surfaceTint: Colors.transparent,
      outline: const Color(0xFF55514B),
      outlineVariant: Stage.line,
      error: const Color(0xFFFF6B5E),
      onError: Stage.onTape,
      errorContainer: const Color(0xFF3A1714),
      onErrorContainer: const Color(0xFFFFD6D0),
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: AppType.family,
      scaffoldBackgroundColor: Stage.bg,
    );
    final text = AppType.apply(base.textTheme);
    final label = AppType.button(text);
    const shape = RoundedRectangleBorder(borderRadius: Radii.mdAll);
    const panel = RoundedRectangleBorder(borderRadius: Radii.lgAll);
    const outline = BorderSide(color: Color(0xFF4A4641), width: 1.5);
    return base.copyWith(
      textTheme: text,
      // ThemeData's text theme carries no sizes until Theme.of merges in the
      // typography; the app bar style is used as is, so it gets them here.
      appBarTheme: AppBarTheme(
        backgroundColor: Stage.bg,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleTextStyle:
            base.typography.englishLike.titleLarge!.merge(text.titleLarge).copyWith(color: scheme.onSurface),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(textStyle: label, shape: shape)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(textStyle: label, shape: shape, side: outline, foregroundColor: Stage.ink)),
      textButtonTheme:
          TextButtonThemeData(style: TextButton.styleFrom(textStyle: label, shape: shape, foregroundColor: Stage.ink)),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(shape: shape)),
      segmentedButtonTheme: SegmentedButtonThemeData(
          style: SegmentedButton.styleFrom(
              textStyle: label,
              shape: shape,
              foregroundColor: Stage.muted,
              selectedBackgroundColor: Stage.tape,
              selectedForegroundColor: Stage.onTape,
              side: outline)),
      cardTheme: const CardThemeData(elevation: Elevation.card, color: Stage.panel, shape: panel),
      dialogTheme: const DialogThemeData(backgroundColor: Stage.panelHigh, shape: panel),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Stage.panel),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Stage.panelHigh,
        contentTextStyle: text.bodyLarge?.copyWith(color: scheme.onSurface),
        actionTextColor: Stage.tape,
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
      chipTheme: const ChipThemeData(shape: RoundedRectangleBorder(borderRadius: Radii.smAll)),
      sliderTheme: const SliderThemeData(inactiveTrackColor: Stage.line),
      dividerTheme: const DividerThemeData(color: Stage.line),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: Stage.tape),
    );
  }
}
