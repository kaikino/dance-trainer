import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import 'style.dart';

/// The steps in the order a beginner meets them.
const _legendSteps = [
  StepClass.forward,
  StepClass.back,
  StepClass.sideOut,
  StepClass.sideIn,
  StepClass.cross,
  StepClass.kick,
  StepClass.inPlace,
];

/// What a verdict colour means, one line each.
String _verdictHelp(Verdict v) => switch (v) {
      Verdict.correct => 'The right step, on the beat.',
      Verdict.wrongStep => 'A different step from the one on the chart.',
      Verdict.offBeat => 'The right step, but early or late.',
      Verdict.missed => 'No step was felt on that beat.',
      _ => '',
    };

/// A bottom sheet with every step's icon, name and one plain sentence, and
/// what the chart's colours mean. Built from the same icons and names as the chart.
Future<void> showStepLegend(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (context) => const StepLegend(),
    );

class StepLegend extends StatelessWidget {
  const StepLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget badge(IconData? icon, Color bg, Color fg) => Container(
          width: 40,
          height: 40,
          margin: const EdgeInsets.only(right: Space.sm),
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: icon == null ? null : Icon(icon, color: fg, size: 24),
        );
    Widget row({required List<Widget> leading, required String title, required String text}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          child: Row(
            children: [
              SizedBox(width: 92, child: Row(children: leading)),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '$title  ', style: const TextStyle(fontWeight: AppType.heavy)),
                    TextSpan(text: text, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
        );
    String cap(String s) => s[0].toUpperCase() + s.substring(1);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.xl),
        children: [
          Text('The steps', style: theme.textTheme.heading),
          const SizedBox(height: Space.xs),
          Text('Left foot, then right foot. Arrows point the way the foot moves, seen from behind you.',
              style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Space.sm),
          for (final c in _legendSteps)
            row(
              leading: [
                for (final f in Role.values) badge(stepIcon(c, f), scheme.primary, scheme.onPrimary),
              ],
              title: cap(stepLabel(c)),
              text: stepHelp(c),
            ),
          const SectionHeader('Colours'),
          for (final v in scoredVerdicts)
            row(
              leading: [badge(v.icon, v.fill, Colors.white)],
              title: cap(v.label),
              text: _verdictHelp(v),
            ),
        ],
      ),
    );
  }
}
