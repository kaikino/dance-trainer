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

/// End-of-session numbers: accuracy as a ring (first-try accuracy in
/// Practice), timing, mistakes by type and by foot and step, a drill button
/// for the worst one, and an export button that shares the session files.
/// Two columns in landscape (stats | mistakes); actions pinned at the bottom.
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

  void _dance(BuildContext context, SessionKind kind, {double fromBeat = 1}) => Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DanceScreen(manager: manager, preset: preset, kind: kind, dancer: dancer, fromBeat: fromBeat),
        ),
      );

  Future<void> _export() => Share.shareXFiles(
        [for (final f in recorder.files) XFile(f.path)],
        subject: 'Dance Trainer session ${recorder.sessionId}',
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Session summary')),
      bottomNavigationBar: BottomActions(
        maxWidth: 1100,
        children: [
          FilledButton.icon(
            onPressed: () => _dance(context, kind),
            icon: const Icon(Icons.replay_rounded),
            label: const Text('Try again'),
          ),
          // Icon only on a phone, where the word does not fit.
          MediaQuery.sizeOf(context).width < 600
              ? OutlinedButton(
                  onPressed: _export,
                  child: const Icon(Icons.ios_share_rounded, semanticLabel: 'Export'),
                )
              : OutlinedButton.icon(
                  onPressed: _export,
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Export'),
                ),
          OutlinedButton(
            onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
            child: const Text('Done'),
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preset.name, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              StatusPill(icon: Icons.speed_rounded, text: '${preset.bpm.round()} bpm'),
              StatusPill(icon: kind.icon, text: kind.title, color: theme.colorScheme.primary),
            ]),
          ],
        );
        final List<Widget> left, right;
        if (kind == SessionKind.capture) {
          left = [_captureStats(context)];
          right = const [];
        } else {
          left = _stats(context, wide);
          right = _mistakes(context);
        }
        final content = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
                  if (right.isNotEmpty) ...[
                    const SizedBox(width: 32),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
                  ],
                ],
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...left, ...right]);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            ContentWidth(
              maxWidth: wide ? 1100 : 720,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [header, const SizedBox(height: 8), content]),
            ),
          ],
        );
      }),
    );
  }

  List<Widget> _stats(BuildContext context, bool wide) {
    final theme = Theme.of(context);
    final practice = kind == SessionKind.practice;
    final acc = score.accuracy;
    final first = score.firstTryAccuracy;
    final meanErr = score.meanTimingMs;
    final hardest = score.hardestBar;
    final ring = ScoreRing(
      value: practice ? first : acc,
      caption: practice ? 'right first time' : 'correct',
      size: wide ? 200 : 150,
    );
    final facts = [
      _Fact(Icons.done_all_rounded, '${score.judged}/${preset.steps.length}', 'steps judged'),
      _Fact(Icons.timer_outlined, meanErr == null ? '–' : '${meanErr >= 0 ? '+' : ''}${meanErr.round()} ms',
          meanErr == null ? 'timing' : (meanErr >= 0 ? 'late on average' : 'early on average')),
      if (practice) ...[
        _Fact(Icons.verified_rounded, acc == null ? '–' : '${(acc * 100).round()}%', 'after retries'),
        _Fact(Icons.replay_rounded, '${score.rewinds}', score.rewinds == 1 ? 'rewind' : 'rewinds'),
      ],
    ];
    return [
      const SectionHeader('Score'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              ring,
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in facts) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: f)
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      if (hardest != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Card(
            color: theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.local_fire_department_rounded, color: theme.colorScheme.onTertiaryContainer, size: 28),
                  const SizedBox(width: 14),
                  Text('Hardest bar: ${hardest.bar}',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.onTertiaryContainer)),
                  const Spacer(),
                  Text('${hardest.tries} tries',
                      style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          for (final v in scoredVerdicts.skip(1)) Expanded(child: _VerdictTile(verdict: v, count: score.count(v))),
        ],
      ),
      if (score.extras > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 4),
          child: Text('${score.extras} extra ${score.extras == 1 ? 'step' : 'steps'} off the schedule',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
    ];
  }

  List<Widget> _mistakes(BuildContext context) {
    final theme = Theme.of(context);
    final mistakes = score.mistakesByStep();
    if (mistakes.isEmpty) {
      return [
        const SectionHeader('To work on'),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            leading: Icon(score.judged == 0 ? Icons.info_outline_rounded : Icons.celebration_rounded,
                color: score.judged == 0 ? null : Verdict.correct.color, size: 32),
            title: Text(score.judged == 0 ? 'No steps were judged.' : 'No mistakes. Clean run!',
                style: theme.textTheme.titleMedium),
          ),
        ),
      ];
    }
    final top = mistakes.first;
    final drillFrom = Preset.barStart(preset.steps[top.first].beat);
    return [
      const SectionHeader('To work on'),
      // A real button: Practice this routine from the bar the worst step first went wrong in.
      SizedBox(
        height: 72,
        child: FilledButton.tonal(
          onPressed: () => _dance(context, SessionKind.practice, fromBeat: drillFrom),
          style: FilledButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 20),
          ),
          child: Row(
            children: [
              const Icon(Icons.fitness_center_rounded, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Drill: ${footName(top.foot).toLowerCase()} foot, ${stepLabel(top.step)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('Practice from bar ${barOf(drillFrom)}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < mistakes.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 72),
              _MistakeRow(group: mistakes[i]),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _captureStats(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Recording'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Fact(Icons.directions_walk_rounded, '${recorder.events.length}', 'steps recorded'),
                for (final r in Role.values)
                  _Fact(Icons.sensors_rounded, '${recorder.sampleCounts[r] ?? 0}',
                      '${footName(r).toLowerCase()} samples'),
                const SizedBox(height: 12),
                Text('Labels were assigned from the schedule; export the files and run ml/label.py to check them.',
                    style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// An icon, a big value and what it means: on one line, or the meaning under
/// the value where the line is short (phone).
class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.value, this.label);
  final IconData icon;
  final String value, label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueText = Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800));
    final labelText = Text(label, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    return LayoutBuilder(
      builder: (context, c) => Row(
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          if (c.maxWidth < 280)
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [valueText, labelText]))
          else ...[
            valueText,
            const SizedBox(width: 8),
            Flexible(child: labelText),
          ],
        ],
      ),
    );
  }
}

/// A mistake count with its verdict icon and colour; neutral at zero.
class _VerdictTile extends StatelessWidget {
  const _VerdictTile({required this.verdict, required this.count});
  final Verdict verdict;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = count == 0 ? theme.colorScheme.onSurfaceVariant : verdict.color;
    return Card(
      color: count == 0 ? null : verdict.color.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            children: [
              Text('$count',
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: color)),
              const SizedBox(width: 10),
              Icon(verdict.icon, color: color, size: 20),
              const SizedBox(width: 4),
              Text(verdict.label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One foot-and-step group: the step's icon, its name, how many, and what
/// kind of mistakes they were.
class _MistakeRow extends StatelessWidget {
  const _MistakeRow({required this.group});
  final MistakeGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = stepIcon(group.step, group.foot);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: Colors.white,
        child: icon == null ? null : Icon(icon),
      ),
      title: Text('${footName(group.foot)} foot, ${stepLabel(group.step)}',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final v in scoredVerdicts)
              if (group.byVerdict[v] case final n?) StatusPill(icon: v.icon, text: '$n ${v.label}', color: v.color),
          ],
        ),
      ),
      trailing: Text('${group.count}', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
    );
  }
}
