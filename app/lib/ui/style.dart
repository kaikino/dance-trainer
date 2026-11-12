import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/protocol.dart';

/// Shared words and colours, so every screen names steps and verdicts the same way.

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

String footName(Role r) => r == Role.left ? 'Left' : 'Right';

/// Colour and name for each verdict. Pending steps use the theme's primary.
extension VerdictStyle on Verdict {
  Color get color => switch (this) {
        Verdict.correct => const Color(0xFF2E7D32), // green 800
        Verdict.wrongStep => const Color(0xFFC62828), // red 800
        Verdict.offBeat => const Color(0xFFE65100), // orange 900, reads as amber, white text stays legible
        Verdict.missed => const Color(0xFF6E6E6E), // neutral grey, apart from the indigo of pending steps
        Verdict.extra || Verdict.unjudged => const Color(0xFF9E9E9E),
      };

  String get label => switch (this) {
        Verdict.correct => 'correct',
        Verdict.wrongStep => 'wrong step',
        Verdict.offBeat => 'off beat',
        Verdict.missed => 'missed',
        Verdict.extra => 'extra',
        Verdict.unjudged => 'not judged',
      };
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
