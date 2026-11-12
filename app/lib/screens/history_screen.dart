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
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      ContentWidth(
                        maxWidth: wide ? 1100 : 720,
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 5, child: overview),
                                  const SizedBox(width: 32),
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('No sessions yet', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 6),
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
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                ScoreRing(value: best, caption: best == null ? 'no full run yet' : 'best', size: wide ? 170 : 132),
                const SizedBox(width: 24),
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
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: _Trend(entries: entries.take(12).toList().reversed.toList()),
          ),
        ),
      ],
    );
  }
}

/// One bar per run, oldest on the left; an incomplete run is an outline.
class _Trend extends StatelessWidget {
  const _Trend({required this.entries});
  final List<HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const h = 120.0;
    return Semantics(
      label: 'Recent scores: ${entries.map((e) => e.headline == null ? 'none' : '${(e.headline! * 100).round()}%').join(', ')}',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: h,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final e in entries)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Container(
                        height: 6 + (h - 6) * (e.headline ?? 0),
                        decoration: BoxDecoration(
                          color: e.complete && e.headline != null ? accuracyColor(context, e.headline!) : null,
                          border: e.complete ? null : Border.all(color: scheme.outline, width: 2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                // Keep bars narrow with only a few runs.
                for (var i = entries.length; i < 8; i++) const Expanded(child: SizedBox()),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Older', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const Spacer(),
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outline, width: 2),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 6),
              Text('Incomplete', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const Spacer(),
              Text('Latest', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
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
        const SizedBox(height: 8),
        Text('Practice is scored right first time; Performance on every step.',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _row(BuildContext context, HistoryEntry e, {required bool isBest}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final h = e.headline;
    final bpm = e.bpmMin.round() == e.bpmMax.round() ? '${e.bpmMax.round()} bpm' : '${e.bpmMax.round()} → ${e.bpmMin.round()} bpm';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: Icon(e.kind.icon),
      ),
      title: Text(friendlyDate(e.date), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${e.kind.title} · $bpm · ${e.judged}/${e.steps} steps'),
            if (!e.complete) const StatusPill(icon: Icons.timelapse_rounded, text: 'Incomplete'),
            if (isBest) StatusPill(icon: Icons.emoji_events_rounded, text: 'Best', color: okColor(context)),
          ],
        ),
      ),
      trailing: Text(
        h == null ? '–' : '${(h * 100).round()}%',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: h == null || !e.complete ? scheme.onSurfaceVariant : accuracyColor(context, h),
        ),
      ),
    );
  }
}
