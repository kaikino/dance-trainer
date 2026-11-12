import 'package:flutter/material.dart';

/// Design tokens: spacing, radii, elevation, the type scale and status
/// colours. The theme (main.dart) is built from them and every screen takes
/// its sizes from here instead of its own numbers.

/// Spacing on a 4 dp grid.
abstract final class Space {
  static const double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32;

  /// Screen side margin: 16 on a phone, 24 on a tablet.
  static double gutter(BuildContext context) => isTablet(context) ? xl : lg;

  /// Tablet layout from this width.
  static bool isTablet(BuildContext context) => MediaQuery.sizeOf(context).width >= 600;

  /// Readable width of a single centred column.
  static const double column = 720;
}

/// Corner radii.
abstract final class Radii {
  static const double sm = 8, md = 16, lg = 24, full = 999;
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius fullAll = BorderRadius.all(Radius.circular(full));
}

/// Cards sit flat; overlays (hold cards, banners) lift a little on
/// surfaceContainerHigh.
abstract final class Elevation {
  static const double card = 0, overlay = 3;
}

/// Touch targets: every main button is this tall.
abstract final class Sizes {
  static const double button = 56;
}

/// How long state changes fade (hold cards, banners, screen states).
abstract final class Motion {
  static const Duration fade = Duration(milliseconds: 200);
}

/// The type scale, as roles. Weights are 400, 600 and 800 only.
///
/// | role      | style          | weight |
/// | display   | displaySmall   | 800    | score, count-in
/// | heading   | headlineSmall  | 800    | screen and card headlines
/// | cardTitle | titleMedium    | 600    |
/// | body      | bodyLarge      | 400    |
/// | label     | labelLarge     | 600    | pills, chips, small labels
/// | overline  | labelLarge     | 600, tracking 1.4, upper case | section headers
/// | button    | titleMedium    | 600, 16 sp |
abstract final class AppType {
  static const regular = FontWeight.w400, strong = FontWeight.w600, heavy = FontWeight.w800;

  /// [base] with the scale's weights applied; the theme uses this.
  static TextTheme apply(TextTheme base) => base.copyWith(
        displayLarge: base.displayLarge?.copyWith(fontWeight: heavy),
        displayMedium: base.displayMedium?.copyWith(fontWeight: heavy),
        displaySmall: base.displaySmall?.copyWith(fontWeight: heavy),
        headlineLarge: base.headlineLarge?.copyWith(fontWeight: heavy),
        headlineMedium: base.headlineMedium?.copyWith(fontWeight: heavy),
        headlineSmall: base.headlineSmall?.copyWith(fontWeight: heavy),
        titleLarge: base.titleLarge?.copyWith(fontWeight: strong),
        titleMedium: base.titleMedium?.copyWith(fontWeight: strong),
        titleSmall: base.titleSmall?.copyWith(fontWeight: strong),
        bodyLarge: base.bodyLarge?.copyWith(fontWeight: regular),
        bodyMedium: base.bodyMedium?.copyWith(fontWeight: regular),
        bodySmall: base.bodySmall?.copyWith(fontWeight: regular),
        labelLarge: base.labelLarge?.copyWith(fontWeight: strong),
        labelMedium: base.labelMedium?.copyWith(fontWeight: strong),
        labelSmall: base.labelSmall?.copyWith(fontWeight: strong),
      );

  /// Buttons: titleMedium, 16 sp, semi-bold.
  static TextStyle button(TextTheme t) => t.titleMedium!.copyWith(fontSize: 16, fontWeight: strong);
}

/// The type roles by name: `Theme.of(context).textTheme.heading`.
extension TypeRoles on TextTheme {
  TextStyle get display => displaySmall!;
  TextStyle get heading => headlineSmall!;
  TextStyle get cardTitle => titleMedium!;
  TextStyle get body => bodyLarge!;
  TextStyle get label => labelLarge!;
  TextStyle get overline => labelLarge!.copyWith(fontWeight: AppType.strong, letterSpacing: 1.4);
}

/// Status (a node calibrated or not, a reconnect, progress), kept apart from
/// the verdict colours, which mean only how a step was judged. Teal and amber,
/// so "calibrated" never reads as "correct" nor "needs attention" as "off beat".
abstract final class StatusColors {
  /// Text and icons on the theme's surfaces (at least 4.5:1).
  static Color ok(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? const Color(0xFF4DB6AC) : const Color(0xFF00695C);
  static Color warn(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFFCA28) : const Color(0xFF7A5300);

  /// A solid background under white text (the "reconnected" toast).
  static const okFill = Color(0xFF00796B);
}

/// The foot drawings (live view, feet diagram) share these.
abstract final class FootColors {
  /// The toe cap: the sole's own colour, darkened. Same rule everywhere.
  static Color cap(Color sole) => Color.lerp(sole, Colors.black, 0.28)!;

  /// The shadow on the floor, in both themes.
  static const shadow = Color(0x40000000); // black @ 0.25
}
