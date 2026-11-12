import 'package:flutter/material.dart';

import '../models/preset.dart';
import '../models/session_kind.dart';
import '../store/history.dart';
import '../ui/dates.dart';
import '../ui/style.dart';

/// Past sessions of one routine: the best score, how the recent runs went,
/// and every session newest first. Runs ended early are listed as
/// Incomplete and never count as the best.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.preset});
  final Preset preset;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    SessionHistory.load(presetId: widget.preset.id).then((e) {
      if (mounted) setState(() => _entries = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.preset.name}: history')),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? _empty(context)
              : LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth >= 900;
                  final overview = _Overview(entries: entries, wide: wide);
                  final list = _SessionList(entries: entries);
                  return ListView(
                    padding: EdgeInsets.fromLTRB(Space.gutter(context), Space.sm, Space.gutter(context), Space.xl),
                    children: [
                      ContentWidth(
                        maxWidth: wide ? 1100 : 720,
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 5, child: overview),
                                  const SizedBox(width: Space.xxl),
                                  Expanded(flex: 6, child: list),
                                ],
                              )
                            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [overview, list]),
                      ),
                    ],
                  );
                }),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: Space.md),
            Text('No sessions yet', style: theme.textTheme.headlineSmall),
            const SizedBox(height: Space.sm),
            Text('Dance this routine and your scores will show up here.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// The best score as a ring, a few counts, and the recent runs as bars.
class _Overview extends StatelessWidget {
  const _Overview({required this.entries, required this.wide});
  final List<HistoryEntry> entries;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final best = SessionHistory.best(entries);
    final full = entries.where((e) => e.complete).length;
    final last = entries.where((e) => e.complete && e.headline != null).firstOrNull;
    Widget fact(String value, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: AppType.heavy)),
              const SizedBox(width: Space.sm),
              Flexible(
                child:
                    Text(label, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Best', top: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Row(
              children: [
                ScoreRing(value: best, caption: best == null ? 'no full run yet' : 'best', size: wide ? 170 : 132),
                const SizedBox(width: Space.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      fact('${entries.length}', entries.length == 1 ? 'session' : 'sessions'),
                      fact('$full', full == 1 ? 'full run' : 'full runs'),
                      if (last != null) fact('${(last.headline! * 100).round()}%', 'last full run'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SectionHeader('Recent runs'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.xl, Space.lg, Space.md),
            child: _Trend(entries: entries.take(12).toList().reversed.toList()),
          ),
        ),
      ],
    );
  }
}

/// One bar per run, oldest on the left; an incomplete run is an outline.
/// The runs share the whole width (one slot each, the bar centred in it), and
/// "Older" and "Latest" sit under the first and last bars.
class _Trend extends StatelessWidget {
  const _Trend({required this.entries});
  final List<HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const h = 120.0, maxBar = 32.0;
    final caption = theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant);
    final n = entries.length;
    Widget slots(Widget Function(int i, double barWidth) cell) => LayoutBuilder(
          builder: (context, c) {
            final slot = c.maxWidth / n;
            final bar = (slot * 0.6).clamp(8.0, maxBar);
            return Row(children: [for (var i = 0; i < n; i++) SizedBox(width: slot, child: cell(i, bar))]);
          },
        );
    return Semantics(
      label:
          'Recent scores: ${entries.map((e) => e.headline == null ? 'none' : '${(e.headline! * 100).round()}%').join(', ')}',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: h,
            child: slots((i, bar) {
              final e = entries[i];
              return Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: bar,
                  height: 6 + (h - 6) * (e.headline ?? 0),
                  decoration: BoxDecoration(
                    color: e.complete && e.headline != null ? scheme.primary : null,
                    border: e.complete ? null : Border.all(color: scheme.outline, width: 2),
                    borderRadius: Radii.smAll,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: Space.sm),
          // Under the first and last bars; one run is the latest.
          SizedBox(
              // One line of the caption, at the user's text size.
              height: MediaQuery.textScalerOf(context).scale(caption?.fontSize ?? 12) * 1.5,
              child: slots((i, _) => OverflowBox(
                    maxWidth: double.infinity,
                    child: Text(
                      i == n - 1 ? 'Latest' : (i == 0 ? 'Older' : ''),
                      style: caption,
                      maxLines: 1,
                    ),
                  ))),
          if (entries.any((e) => !e.complete)) ...[
            const SizedBox(height: Space.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.outline, width: 2),
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                  ),
                ),
                const SizedBox(width: Space.xs),
                Text('Incomplete', style: caption),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({required this.entries});
  final List<HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final best = SessionHistory.best(entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Sessions', top: 16),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 72),
                _row(context, entries[i], isBest: best != null && entries[i].complete && entries[i].headline == best),
              ],
            ],
          ),
        ),
        const SizedBox(height: Space.sm),
        Text('Practice is scored right first time; Performance on every step.',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _row(BuildContext context, HistoryEntry e, {required bool isBest}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final h = e.headline;
    final bpm = e.bpmMin.round() == e.bpmMax.round()
        ? '${e.bpmMax.round()} bpm'
        : '${e.bpmMax.round()} → ${e.bpmMin.round()} bpm';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: Icon(e.kind.icon),
      ),
      title: Text(friendlyDate(e.date), style: theme.textTheme.titleMedium),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: Space.xs),
        child: Wrap(
          spacing: Space.sm,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${e.kind.title} · $bpm · ${e.judged}/${e.steps} steps'),
            if (!e.complete) const StatusPill(icon: Icons.timelapse_rounded, text: 'Incomplete'),
            if (isBest) StatusPill(icon: Icons.emoji_events_rounded, text: 'Best', color: scheme.primary),
          ],
        ),
      ),
      trailing: Text(
        h == null ? '–' : '${(h * 100).round()}%',
        style: theme.textTheme.headlineSmall?.copyWith(
          color: h == null || !e.complete ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
      ),
    );
  }
}
