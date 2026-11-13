import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';
import '../models/session_score.dart';
import '../store/history.dart';
import '../store/session_store.dart';
import '../ui/style.dart';
import 'dance_screen.dart';
import 'preset_screen.dart';

/// End-of-session numbers: accuracy as a ring (first-try accuracy in
/// Practice), timing, mistakes by type and by foot and step, a drill button
/// for the worst one, and an export button that shares the session files.
/// Two columns in landscape (stats | mistakes); actions pinned at the bottom.
class SummaryScreen extends StatefulWidget {
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

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

/// The headline over the score: a tier for how it went and how it compares
/// with the last full run of the same routine and mode.
String summaryHeadline(double? score, {double? previous, bool complete = true}) {
  if (score == null) return 'No steps were judged';
  if (!complete) return 'Ended early';
  final tier = switch (score) {
    >= 0.95 => 'Superb!',
    >= 0.85 => 'Great job!',
    >= 0.7 => 'Nice!',
    >= 0.5 => 'Good effort!',
    _ => 'Keep at it!',
  };
  if (previous == null) return tier;
  final now = (score * 100).round(), before = (previous * 100).round();
  if (now > before) return '$tier Up from $before%';
  if (now == before) return '$tier Same as last time';
  return '$tier Last time $before%';
}

/// Mean timing error in plain words (+ = late).
String timingAdvice(double? meanMs) => switch (meanMs?.roundToDouble()) {
      null => 'No timed steps',
      final e when e.abs() <= 40 => 'Right on the beat',
      final e when e > 120 => 'Behind the beat: step earlier',
      final e when e > 0 => 'Slightly behind the beat: try stepping a touch earlier',
      final e when e < -120 => 'Ahead of the beat: wait for it',
      _ => 'Slightly ahead of the beat: try waiting a touch longer',
    };

class _SummaryScreenState extends State<SummaryScreen> {
  HistoryEntry? _self, _previous;

  /// null while saving; true once this run is in Documents/DanceTrainer.
  bool? _saved = false;

  NodeManager get manager => widget.manager;
  Preset get preset => widget.preset;
  SessionKind get kind => widget.kind;
  String get dancer => widget.dancer;
  SessionRecorder get recorder => widget.recorder;
  SessionScore get score => widget.score;

  @override
  void initState() {
    super.initState();
    if (kind != SessionKind.capture) _loadHistory();
    recorder.isSaved().then((v) {
      if (mounted && v) setState(() => _saved = true);
    });
  }

  Future<void> _loadHistory() async {
    final all = await SessionHistory.load(presetId: preset.id);
    if (!mounted) return;
    setState(() {
      _self = all.where((e) => e.sessionId == recorder.sessionId).firstOrNull;
      _previous = SessionHistory.previous(all, presetId: preset.id, kind: kind, sessionId: recorder.sessionId);
    });
  }

  void _dance(BuildContext context, SessionKind kind, {double fromBeat = 1}) => Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DanceScreen(manager: manager, preset: preset, kind: kind, dancer: dancer, fromBeat: fromBeat),
        ),
      );

  /// Keeps this run: copies its files to Documents/DanceTrainer/<session> on
  /// the tablet. (Every run is recorded in the app's own folder anyway; that
  /// one is not reachable from a computer and goes with the app.)
  Future<void> _save() async {
    setState(() => _saved = null);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await recorder.saveToDevice();
      if (!mounted) return;
      setState(() => _saved = true);
      messenger.showSnackBar(SnackBar(content: Text('Saved to Documents/DanceTrainer/${recorder.sessionId}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saved = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  Future<void> _export() => Share.shareXFiles(
        [for (final f in recorder.files) XFile(f.path)],
        subject: 'Dance Trainer session ${recorder.sessionId}',
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Session summary'),
        actions: [
          // Sharing the files (email, Drive, …) is still here, out of the way.
          IconButton(onPressed: _export, icon: const Icon(Icons.ios_share_rounded), tooltip: 'Share the files'),
        ],
      ),
      bottomNavigationBar: BottomActions(
        maxWidth: 1100,
        children: [
          FilledButton.icon(
            onPressed: () => _dance(context, kind),
            icon: const Icon(Icons.replay_rounded),
            label: const Text('Try again'),
          ),
          OutlinedButton.icon(
            onPressed: _saved == false ? _save : null,
            icon: switch (_saved) {
              null => const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              true => const Icon(Icons.check_rounded),
              false => const Icon(Icons.save_alt_rounded),
            },
            label: Text(_saved == true ? 'Saved' : 'Save'),
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
            Text(preset.name, style: theme.textTheme.headlineMedium),
            const SizedBox(height: Space.sm),
            Wrap(spacing: Space.sm, runSpacing: Space.sm, children: [
              StatusPill(
                  icon: Icons.speed_rounded,
                  text: tempoLabel([for (final g in recorder.segments) g.bpm], fallback: preset.bpm)),
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
                    const SizedBox(width: Space.xxl),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
                  ],
                ],
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...left, ...right]);
        return ListView(
          padding: EdgeInsets.fromLTRB(Space.gutter(context), Space.lg, Space.gutter(context), Space.xl),
          children: [
            ContentWidth(
              maxWidth: wide ? 1100 : 720,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [header, const SizedBox(height: Space.sm), content]),
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
    final headline = practice ? first : acc;
    final complete = _self?.complete ?? true;
    final prev = complete ? _previous?.headline : null;
    final delta = headline == null || prev == null ? null : (headline * 100).round() - (prev * 100).round();
    final ring = ScoreRing(
      value: practice ? first : acc,
      caption: practice ? 'right first time' : 'correct',
      size: wide ? 200 : 150,
    );
    final facts = [
      _Fact(Icons.done_all_rounded, '${score.judged}/${preset.steps.length}', 'steps judged'),
      _Fact(Icons.timer_rounded, meanErr == null ? '–' : '${meanErr.round() > 0 ? '+' : ''}${meanErr.round()} ms',
          timingAdvice(meanErr)),
      if (practice) ...[
        _Fact(Icons.verified_rounded, acc == null ? '–' : '${(acc * 100).round()}%', 'after retries'),
        _Fact(Icons.replay_rounded, '${score.rewinds}', score.rewinds == 1 ? 'rewind' : 'rewinds'),
      ],
    ];
    return [
      const SectionHeader('Score'),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.md),
        child: Wrap(
          spacing: Space.md,
          runSpacing: Space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(summaryHeadline(headline, previous: prev, complete: complete), style: theme.textTheme.headlineSmall),
            if (delta != null)
              StatusPill(
                icon: delta > 0
                    ? Icons.trending_up_rounded
                    : delta < 0
                        ? Icons.trending_down_rounded
                        : Icons.trending_flat_rounded,
                text: '${delta > 0 ? '+' : ''}$delta% vs last time',
                color: delta > 0 ? theme.colorScheme.primary : null,
              ),
            if (!complete)
              Text('Dance to the end for it to count towards your best.',
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Row(
            children: [
              ring,
              const SizedBox(width: Space.xl),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in facts) Padding(padding: const EdgeInsets.symmetric(vertical: Space.sm), child: f)
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      if (hardest != null)
        Padding(
          padding: const EdgeInsets.only(top: Space.md),
          child: Card(
            color: theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.md),
              child: Row(
                children: [
                  Icon(Icons.local_fire_department_rounded, color: theme.colorScheme.onTertiaryContainer, size: 28),
                  const SizedBox(width: Space.md),
                  Text('Hardest bar: ${hardest.bar}',
                      style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                  const Spacer(),
                  Text('${hardest.tries} tries',
                      style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: Space.md),
      Row(
        children: [
          for (final v in scoredVerdicts.skip(1)) Expanded(child: _VerdictTile(verdict: v, count: score.count(v))),
        ],
      ),
      if (score.extras > 0)
        Padding(
          padding: const EdgeInsets.only(top: Space.sm, left: Space.xs),
          child: Text('${Verdict.extra.counted(score.extras)} off the schedule',
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
            contentPadding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.sm),
            leading: Icon(score.judged == 0 ? Icons.info_outline_rounded : Icons.celebration_rounded,
                color: score.judged == 0 ? null : theme.colorScheme.primary, size: 32),
            title: Text(score.judged == 0 ? 'No steps were judged.' : 'No mistakes. Clean run!',
                style: theme.textTheme.titleMedium),
          ),
        ),
      ];
    }
    final top = mistakes.first;
    final drillFrom = preset.barStart(preset.steps[top.first].beat);
    return [
      const SectionHeader('To work on'),
      // A real button: Practice this routine from the bar the worst step first went wrong in.
      SizedBox(
        height: 72,
        child: FilledButton.tonal(
          onPressed: () => _dance(context, SessionKind.practice, fromBeat: drillFrom),
          style: FilledButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: Space.xl),
          ),
          child: Row(
            children: [
              const Icon(Icons.fitness_center_rounded, size: 28),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Drill: ${footName(top.foot).toLowerCase()} foot, ${stepLabel(top.step, top.foot)}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('Practice from bar ${barOf(drillFrom, preset.beatsPerBar)}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
      const SizedBox(height: Space.md),
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
            padding: const EdgeInsets.all(Space.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Fact(Icons.directions_walk_rounded, '${recorder.events.length}', 'steps recorded'),
                for (final r in Role.values)
                  _Fact(Icons.sensors_rounded, '${recorder.sampleCounts[r] ?? 0}',
                      '${footName(r).toLowerCase()} samples'),
                const SizedBox(height: Space.md),
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

/// The session's tempo: "96 bpm", or "96 → 77 bpm" when Practice slowed it
/// down. [bpms] is one per segment, in order; [fallback] when there is none.
String tempoLabel(List<double> bpms, {required double fallback}) {
  final first = (bpms.firstOrNull ?? fallback).round();
  final last = (bpms.lastOrNull ?? fallback).round();
  return first == last ? '$first bpm' : '$first → $last bpm';
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
    final valueText = Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: AppType.heavy));
    final labelText =
        Text(label, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    return LayoutBuilder(
      builder: (context, c) => Row(
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: Space.md),
          if (c.maxWidth < 280)
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [valueText, labelText]))
          else ...[
            valueText,
            const SizedBox(width: Space.sm),
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
    final ink = verdict.ink(context);
    final color = count == 0 ? theme.colorScheme.onSurfaceVariant : ink;
    Widget content(String n, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(n, style: theme.textTheme.headlineMedium?.copyWith(color: color)),
            const SizedBox(width: Space.sm),
            Icon(verdict.icon, color: color, size: 20),
            const SizedBox(width: Space.xs),
            Text(label, style: theme.textTheme.cardTitle.copyWith(color: color)),
          ],
        );
    return Semantics(
      label: verdict.counted(count),
      excludeSemantics: true,
      child: Card(
        color: count == 0 ? null : Color.alphaBlend(ink.withValues(alpha: 0.12), theme.colorScheme.surfaceContainer),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.md, horizontal: Space.md),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedLike(
              alignment: AlignmentDirectional.centerStart,
              sizer: content('00', widestVerdictLabel),
              child: content('$count', verdict.labelFor(count)),
            ),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
        child: icon == null ? null : Icon(icon),
      ),
      title: Text('${footName(group.foot)} foot, ${stepLabel(group.step, group.foot)}', style: theme.textTheme.titleMedium),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: Space.sm),
        child: Wrap(
          spacing: Space.sm,
          runSpacing: Space.xs,
          children: [
            for (final v in scoredVerdicts)
              if (group.byVerdict[v] case final n?) StatusPill(icon: v.icon, text: v.counted(n), color: v.ink(context)),
            // What was danced instead, so the fix is clear.
            for (final MapEntry(key: did, value: n) in group.didInstead.entries)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text('Did ${stepLabel(did, group.foot)} instead of ${stepLabel(group.step, group.foot)} ×$n',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
      trailing: Text('${group.count}', style: theme.textTheme.headlineSmall),
    );
  }
}
