import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import '../models/preset.dart';

/// Shared words, colours, icons and small widgets, so every screen names and
/// draws steps and verdicts the same way.

/// Short human name for a step class, as the dancer reads it ("side out", "tap").
String stepLabel(StepClass c) => switch (c) {
      StepClass.forward => 'forward',
      StepClass.back => 'back',
      StepClass.sideOut => 'side out',
      StepClass.sideIn => 'side in',
      StepClass.cross => 'cross',
      StepClass.kick => 'kick',
      StepClass.inPlace => 'tap',
      StepClass.none => 'no step',
    };

/// One plain sentence per step, for the step legend.
String stepHelp(StepClass c) => switch (c) {
      StepClass.forward => 'Step this foot forward.',
      StepClass.back => 'Step this foot backward.',
      StepClass.sideOut => 'Step outwards to the side.',
      StepClass.sideIn => 'Bring this foot in beside the other one, without crossing.',
      StepClass.cross => 'Step this foot across the other foot.',
      StepClass.kick => 'Swing the foot forward off the floor.',
      StepClass.inPlace => 'Touch the floor where you stand, no travel.',
      StepClass.none => '',
    };

/// "Left" or "Right"; lower-case it in the middle of a sentence.
String footName(Role r) => r == Role.left ? 'Left' : 'Right';

/// Where a node's calibration stands, from its Status. One rule everywhere:
/// no status yet, or old firmware that does not report it, is [unknown] and
/// is not treated as needing calibration.
enum CalState { unknown, calibrated, boardMoved, tiltOnly, notCalibrated }

CalState calStateOf(Status? st) => switch (st) {
      null || Status(calFlags: null) => CalState.unknown,
      Status(boardMoved: true) => CalState.boardMoved,
      Status(knowsForward: true) => CalState.calibrated,
      Status(calibrated: true) => CalState.tiltOnly,
      _ => CalState.notCalibrated,
    };

extension CalStateX on CalState {
  /// Directions would be judged wrong until the node is calibrated (again).
  bool get needsCalibration =>
      this == CalState.boardMoved || this == CalState.tiltOnly || this == CalState.notCalibrated;
}

/// The stance calibration measures, and the step classifier assumes.
const stanceInstruction = 'Stand with your feet parallel and under your hips, about one foot-width apart, '
    'weight on both feet. Keep still until you feel a buzz.';

/// Arrow for a step, as the dancer sees the chart (left lane = left foot).
/// Side steps point outward and closes point inward; a cross goes inward past
/// the other foot, so it is the inward arrow doubled (as a kick is a doubled
/// forward). Material glyphs, not Unicode arrows, which Android draws as emoji.
IconData? stepIcon(StepClass c, Role foot) {
  final left = foot == Role.left;
  return switch (c) {
    StepClass.forward => Icons.arrow_upward_rounded,
    StepClass.back => Icons.arrow_downward_rounded,
    StepClass.sideOut => left ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded,
    StepClass.sideIn => left ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
    StepClass.cross => left ? Icons.keyboard_double_arrow_right_rounded : Icons.keyboard_double_arrow_left_rounded,
    StepClass.kick => Icons.keyboard_double_arrow_up_rounded,
    StepClass.inPlace => Icons.adjust_rounded,
    StepClass.none => null,
  };
}

/// Colour, name and icon for each verdict. Pending steps use the theme's primary.
///
/// Two colour roles, so each reads in light and dark themes:
/// - [fill]: a solid background under white text and icons (chart footprints,
///   pop labels). The same in both themes.
/// - [ink]: text and icons on the theme's own surfaces: deep shades on light,
///   light tints on dark, each at least 4.5:1 against the surface.
extension VerdictStyle on Verdict {
  Color get fill => switch (this) {
        Verdict.correct => const Color(0xFF2E7D32), // green 800
        Verdict.wrongStep => const Color(0xFFC62828), // red 800
        Verdict.offBeat => const Color(0xFFE65100), // orange 900: reads as amber, white text stays legible
        Verdict.missed => const Color(0xFF546E7A), // slate: apart from the indigo of pending steps and from "empty"
        Verdict.extra || Verdict.unjudged => const Color(0xFF757575),
      };

  Color inkFor(Brightness b) => b == Brightness.dark
      ? switch (this) {
          Verdict.correct => const Color(0xFF81C784),
          Verdict.wrongStep => const Color(0xFFEF9A9A),
          Verdict.offBeat => const Color(0xFFFFB74D),
          Verdict.missed => const Color(0xFFB0BEC5),
          Verdict.extra || Verdict.unjudged => const Color(0xFFBDBDBD),
        }
      : switch (this) {
          Verdict.correct => const Color(0xFF1B5E20),
          Verdict.wrongStep => const Color(0xFFB71C1C),
          Verdict.offBeat => const Color(0xFFB54708),
          Verdict.missed => const Color(0xFF455A64),
          Verdict.extra || Verdict.unjudged => const Color(0xFF616161),
        };

  Color ink(BuildContext context) => inkFor(Theme.of(context).brightness);

  String get label => switch (this) {
        Verdict.correct => 'correct',
        Verdict.wrongStep => 'wrong step',
        Verdict.offBeat => 'off beat',
        Verdict.missed => 'missed',
        Verdict.extra => 'extra',
        Verdict.unjudged => 'not judged',
      };

  IconData get icon => switch (this) {
        Verdict.correct => Icons.check_circle_rounded,
        Verdict.wrongStep => Icons.cancel_rounded,
        Verdict.offBeat => Icons.schedule_rounded,
        Verdict.missed => Icons.remove_circle_outline_rounded,
        Verdict.extra || Verdict.unjudged => Icons.help_outline_rounded,
      };
}

/// The verdicts a dancer is scored on, in display order.
const scoredVerdicts = [Verdict.correct, Verdict.wrongStep, Verdict.offBeat, Verdict.missed];

/// The scored verdict with the longest label, to size a row of tiles by.
final widestVerdict = scoredVerdicts.reduce((a, b) => a.label.length >= b.label.length ? a : b);

/// [child], laid out at least as large as [sizer] (drawn invisibly). In a
/// row of equal tiles, each FittedBox then scales its content by the same
/// factor, so a short label is not drawn bigger than a long one.
class SizedLike extends StatelessWidget {
  const SizedLike({super.key, required this.sizer, required this.child, this.alignment = Alignment.center});
  final Widget sizer, child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => Stack(
        alignment: alignment,
        children: [ExcludeSemantics(child: Visibility.maintain(visible: false, child: sizer)), child],
      );
}

/// Accuracy band colour (ink): green from 85%, amber from 60%, else red.
Color accuracyColor(BuildContext context, double acc) =>
    (acc >= 0.85 ? Verdict.correct : (acc >= 0.6 ? Verdict.offBeat : Verdict.wrongStep)).ink(context);

/// Status text and icons on the theme's surfaces: all good, and needs attention.
Color okColor(BuildContext context) => Verdict.correct.ink(context);
Color warnColor(BuildContext context) => Verdict.offBeat.ink(context);

/// Black or white, whichever reads on [background] (icons on filled circles).
Color onColor(Color background) => background.computeLuminance() > 0.4 ? Colors.black87 : Colors.white;

/// A column that fills the screen when it fits and scrolls when it does not
/// (phone landscape, large text). [Spacer]s in [child] share the spare height.
/// [child] is measured by its intrinsic height, so it must not contain a
/// LayoutBuilder.
class FillScrollView extends StatelessWidget {
  const FillScrollView({super.key, required this.child, this.padding = EdgeInsets.zero});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: max(0, c.maxHeight - padding.vertical)),
            child: IntrinsicHeight(child: child),
          ),
        ),
      );
}

/// Centres content and keeps it at a readable width on a tablet.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 720});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: SizedBox(width: min(maxWidth, c.maxWidth), child: child),
        ),
      );
}

/// Section heading used on every list screen.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing, this.top = 24});
  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A bar of buttons pinned to the bottom of a screen. The first button is the
/// main one and gets the most room.
class BottomActions extends StatelessWidget {
  const BottomActions({super.key, required this.children, this.maxWidth = 720});
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: ContentWidth(
        maxWidth: maxWidth,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(flex: i == 0 ? 2 : 1, child: SizedBox(height: 56, child: children[i])),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small non-interactive status pill: icon plus text, tinted.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Accuracy as a thick coloured ring with the percentage in the middle.
class ScoreRing extends StatelessWidget {
  const ScoreRing({super.key, required this.value, required this.caption, this.size = 180});
  final double? value;
  final String caption;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value;
    final color = v == null ? theme.colorScheme.outline : accuracyColor(context, v);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: v ?? 0,
            strokeWidth: size * 0.075,
            strokeCap: StrokeCap.round,
            color: color,
            backgroundColor: color.withValues(alpha: 0.14),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(v == null ? '–' : '${(v * 100).round()}%',
                    style: TextStyle(fontSize: size * 0.25, fontWeight: FontWeight.w800, color: color, height: 1)),
                const SizedBox(height: 4),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: size * 0.15),
                  child: Text(caption,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A routine's first bars as two rows of small step icons (L over R), one
/// column per beat, so routines can be told apart at a glance.
class StepPatternPreview extends StatelessWidget {
  const StepPatternPreview({super.key, required this.preset, this.beats = 8, this.color, this.footLabels = true});
  final Preset preset;
  final int beats;
  final Color? color;

  /// An "L" and "R" in front of the rows.
  final bool footLabels;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    Widget cell(Role foot, int beat) {
      final s = preset.steps.where((s) => s.foot == foot && s.beat.floor() == beat).firstOrNull;
      final icon = s == null ? null : stepIcon(s.stepClass, foot);
      return Expanded(
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: icon == null ? scheme.outlineVariant.withValues(alpha: 0.35) : c,
              shape: BoxShape.circle,
            ),
            child: icon == null
                ? null
                : FittedBox(child: Padding(padding: const EdgeInsets.all(4), child: Icon(icon, color: onColor(c)))),
          ),
        ),
      );
    }

    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant, height: 1);
    return Semantics(
      label: 'First ${beats ~/ 4} bars, left foot over right foot',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final foot in Role.values)
            Row(children: [
              if (footLabels)
                SizedBox(
                  width: 18,
                  child: Text(foot == Role.left ? 'L' : 'R', style: labelStyle, textAlign: TextAlign.center),
                ),
              for (var b = 1; b <= beats; b++) cell(foot, b),
            ]),
        ],
      ),
    );
  }
}
