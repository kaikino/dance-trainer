import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';
import '../models/session_score.dart';
import '../store/session_store.dart';
import '../ui/style.dart';
import 'dance_screen.dart';
import 'preset_screen.dart';

/// End-of-session numbers: accuracy, timing, mistakes by type and by foot and
/// step (one result per scheduled step, the latest attempt), and an export
/// button that shares the session folder's files.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({
    super.key,
    required this.manager,
    required this.preset,
    required this.kind,
    required this.dancer,
    required this.recorder,
    required this.score,
  });

  final NodeManager manager;
  final Preset preset;
  final SessionKind kind;
  final String dancer;
  final SessionRecorder recorder;
  final SessionScore score;

  void _tryAgain(BuildContext context) => Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DanceScreen(manager: manager, preset: preset, kind: kind, dancer: dancer),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capture = kind == SessionKind.capture;
    final acc = score.accuracy;
    final meanErr = score.meanTimingMs;
    final mistakes = score.mistakesByStep();

    return Scaffold(
      appBar: AppBar(title: const Text('Session summary')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(preset.name, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text('${preset.bpm.round()} bpm · ${kind.title}',
                    style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                if (capture) ...[
                  Row(children: [_stat(context, '${recorder.events.length}', 'steps recorded')]),
                  const SizedBox(height: 16),
                  const Text('Capture session. Labels were assigned from the schedule; '
                      'export the files and run ml/label.py to check them.'),
                ] else ...[
                  Row(
                    children: [
                      _stat(context, acc == null ? '–' : '${(acc * 100).round()}%', 'correct'),
                      _stat(context, '${score.judged}/${preset.steps.length}', 'steps judged'),
                      _stat(context, meanErr == null ? '–' : '${meanErr >= 0 ? '+' : ''}${meanErr.round()} ms',
                          meanErr == null || meanErr >= 0 ? 'avg, late' : 'avg, early'),
                    ],
                  ),
                  Row(
                    children: [
                      for (final v in const [Verdict.wrongStep, Verdict.offBeat, Verdict.missed])
                        _stat(context, '${score.count(v)}', v.label, color: score.count(v) == 0 ? null : v.color),
                    ],
                  ),
                  if (score.extras > 0 || score.rewinds > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, left: 4),
                      child: Text(
                        [
                          if (score.extras > 0)
                            '${score.extras} extra ${score.extras == 1 ? 'step' : 'steps'} off the schedule',
                          if (score.rewinds > 0) '${score.rewinds} ${score.rewinds == 1 ? 'rewind' : 'rewinds'}',
                        ].join(' · '),
                        style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text('Mistakes by foot and step', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  if (mistakes.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(score.judged == 0 ? 'No steps were judged.' : 'No mistakes.',
                          style: theme.textTheme.bodyLarge),
                    )
                  else ...[
                    Card(
                      color: theme.colorScheme.primaryContainer,
                      child: ListTile(
                        leading: Icon(Icons.fitness_center, color: theme.colorScheme.onPrimaryContainer),
                        title: Text(
                          'Drill: ${footName(mistakes.first.foot).toLowerCase()} foot, '
                          '${stepLabel(mistakes.first.step)}',
                          style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    for (final g in mistakes)
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        title: Text('${footName(g.foot)} foot, ${stepLabel(g.step)}', style: theme.textTheme.bodyLarge),
                        trailing: Text('${g.count}', style: theme.textTheme.titleMedium),
                      ),
                  ],
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: () => _tryAgain(context),
                    icon: const Icon(Icons.replay),
                    label: const Text('Try again'),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton.icon(
                          onPressed: () => Share.shareXFiles(
                            [for (final f in recorder.files) XFile(f.path)],
                            subject: 'Dance Trainer session ${recorder.sessionId}',
                          ),
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Export'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton(
                          onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
                          child: const Text('Done'),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String big, String small, {Color? color}) {
    final theme = Theme.of(context);
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            children: [
              FittedBox(
                child: Text(big,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
              ),
              Text(small,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: color ?? theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
