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

/// Corner radii: small, so panels and buttons read as cut, not pillowed.
/// [full] is only for dots.
abstract final class Radii {
  static const double sm = 4, md = 6, lg = 8, full = 999;
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

/// The type scale, as roles. Two bundled faces: Oswald (condensed, for
/// headings and big numbers) and Work Sans (everything else).
///
/// | role      | style          | face, weight |
/// | display   | displaySmall   | Oswald 600   | score, count-in
/// | heading   | headlineSmall  | Oswald 600   | screen and card headlines
/// | (app bar) | titleLarge     | Oswald 600   |
/// | cardTitle | titleMedium    | Work Sans 600 |
/// | body      | bodyLarge      | Work Sans 400 |
/// | label     | labelLarge     | Work Sans 500 | chips, small labels
/// | overline  | labelLarge     | Work Sans 600, tracking 1.4, upper case | section headers
/// | button    | titleMedium    | Work Sans 600, 16 sp |
abstract final class AppType {
  /// Headings and big numbers.
  static const display = 'Oswald';

  /// Everything else, and text drawn by the charts.
  static const family = 'Work Sans';
  static const regular = FontWeight.w400, medium = FontWeight.w500, strong = FontWeight.w600, heavy = FontWeight.w600;

  /// [base] with the scale's weights applied; the theme uses this.
  static TextTheme apply(TextTheme base) {
    TextStyle? head(TextStyle? s) => s?.copyWith(fontFamily: display, fontWeight: heavy, letterSpacing: 0.2);
    return base.copyWith(
      displayLarge: head(base.displayLarge),
      displayMedium: head(base.displayMedium),
      displaySmall: head(base.displaySmall),
      headlineLarge: head(base.headlineLarge),
      headlineMedium: head(base.headlineMedium),
      headlineSmall: head(base.headlineSmall),
      titleLarge: head(base.titleLarge),
      titleMedium: base.titleMedium?.copyWith(fontWeight: strong),
      titleSmall: base.titleSmall?.copyWith(fontWeight: strong),
      bodyLarge: base.bodyLarge?.copyWith(fontWeight: regular),
      bodyMedium: base.bodyMedium?.copyWith(fontWeight: regular),
      bodySmall: base.bodySmall?.copyWith(fontWeight: regular),
      labelLarge: base.labelLarge?.copyWith(fontWeight: medium),
      labelMedium: base.labelMedium?.copyWith(fontWeight: medium),
      labelSmall: base.labelSmall?.copyWith(fontWeight: medium),
    );
  }

  /// Buttons: titleMedium, 16 sp, bold.
  static TextStyle button(TextTheme t) => t.titleMedium!.copyWith(fontSize: 16, fontWeight: strong, letterSpacing: 0.2);
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

/// The palette, after a dance studio: a matte charcoal floor, flat grey
/// panels, and one tape colour (the bright mark dancers put on the floor)
/// for everything the app wants you to press or look at. Pink and blue are
/// only ever the left and right foot; the verdict colours (style.dart) only
/// ever mean how a step was judged.
abstract final class Stage {
  /// Surfaces, from the deepest up: one warm grey family, no tint.
  static const night = Color(0xFF0E0D0C);
  static const bg = Color(0xFF141312);
  static const panel = Color(0xFF1D1C1A);
  static const panelHigh = Color(0xFF272523);
  static const line = Color(0xFF35322E);

  /// Text on those surfaces.
  static const ink = Color(0xFFF2EFE9);
  static const muted = Color(0xFFA6A097);

  /// The one accent: buttons, scores, pending steps, the selected thing.
  static const tape = Color(0xFFD4F04C);

  /// Dark text on [tape].
  static const onTape = Color(0xFF151510);

  /// The feet.
  static const pink = Color(0xFFF472B6);
  static const blue = Color(0xFF38BDF8);
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
