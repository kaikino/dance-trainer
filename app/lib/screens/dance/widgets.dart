part of '../dance_screen.dart';

/// Bar counter and four beat dots, at a fixed height so the chart below never jumps.
class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.text, required this.beatInBar, this.beatsPerBar = 4});
  final String text;
  final int? beatInBar;
  final int beatsPerBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, c) {
      // Smaller beat dots in a narrow side panel (a phone on its side).
      final big = c.maxWidth >= 300 ? 22.0 : 16.0, small = c.maxWidth >= 300 ? 14.0 : 10.0;
      final gap = c.maxWidth >= 300 ? Space.sm : Space.xs;
      return SizedBox(
        height: 64,
        child: Row(
          children: [
            Expanded(
              // Shrinks rather than cuts "Bar 12 of 16" in a narrow side panel or at large text.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(text, maxLines: 1, style: theme.textTheme.headlineMedium),
              ),
            ),
            Semantics(
              label: beatInBar == null ? null : 'beat ${beatInBar! + 1} of $beatsPerBar',
              excludeSemantics: true,
              child: Row(
                children: [
                  for (var i = 0; i < beatsPerBar; i++)
                    Container(
                      width: big,
                      height: big,
                      margin: EdgeInsets.only(left: gap),
                      alignment: Alignment.center,
                      child: Container(
                        width: beatInBar == i ? big : small,
                        height: beatInBar == i ? big : small,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: beatInBar == i ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// The count-in number, huge, over a dimmed chart.
class _CountIn extends StatelessWidget {
  const _CountIn(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.78),
          borderRadius: Radii.lgAll,
        ),
        child: LayoutBuilder(
          builder: (context, c) => Center(
            // Sized from the chart: read from across the room.
            child: Text('$n',
                style: Theme.of(context)
                    .textTheme
                    .display
                    .copyWith(fontSize: c.biggest.shortestSide * 0.45, color: scheme.primary, height: 1)),
          ),
        ),
      ),
    );
  }
}

/// A card centred over a dimmed chart (Paused, errors).
class _CentreCard extends StatelessWidget {
  const _CentreCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
          borderRadius: Radii.lgAll,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: child),
          ),
        ),
      );
}

/// What stopped the music and what happens next: a verdict-coloured edge and
/// icon, a one-line title, a line of detail, and chips or buttons. Sized from
/// the chart so it reads from across the room on a tablet.
class _HoldCard extends StatelessWidget {
  const _HoldCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.detail,
    this.chips = const [],
    this.actions = const [],
    this.fill = false,
  });
  final bool fill;
  final Color color;
  final IconData icon;
  final String title, detail;
  final List<String> chips;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, c) {
      final size = (c.maxWidth * 0.06).clamp(22.0, 36.0);
      // As wide as its text needs (up to the dock's width), or its slot's width.
      final card = Material(
        elevation: Elevation.overlay,
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: Radii.lgAll,
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: Space.sm, color: color),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(size * 0.7, size * 0.6, size * 0.7, size * 0.6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(icon, color: color, size: size * 1.3),
                          SizedBox(width: size * 0.4),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(title,
                                  maxLines: 1,
                                  style: theme.textTheme.heading.copyWith(fontSize: size, color: color, height: 1.1)),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: size * 0.3),
                      Text(detail,
                          style: theme.textTheme.body
                              .copyWith(fontSize: size * 0.62, color: theme.colorScheme.onSurface, height: 1.3)),
                      if (chips.isNotEmpty) ...[
                        SizedBox(height: size * 0.45),
                        Wrap(
                          spacing: Space.sm,
                          runSpacing: Space.sm,
                          children: [
                            for (final t in chips)
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: size * 0.45, vertical: size * 0.15),
                                decoration:
                                    BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: Radii.fullAll),
                                child:
                                    Text(t, style: theme.textTheme.label.copyWith(fontSize: size * 0.55, color: color)),
                              ),
                          ],
                        ),
                      ],
                      if (actions.isNotEmpty) ...[
                        SizedBox(height: size * 0.6),
                        Wrap(
                          spacing: Space.md,
                          runSpacing: Space.sm,
                          children: [for (final a in actions) SizedBox(height: Sizes.button, child: a)],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      return fill ? card : IntrinsicWidth(child: card);
    });
  }
}

/// What the disconnect banner says for the nodes that are missing, or null
/// when none is.
String? disconnectedText(Set<Role> missing) => switch (missing.length) {
      0 => null,
      1 => '${footName(missing.single)} ankle disconnected',
      _ => 'Both ankles disconnected',
    };

/// Stays while any node is missing, with a button to scan for it now (it is
/// also retried in the background).
class _NodeBanner extends StatelessWidget {
  const _NodeBanner({super.key, required this.text, required this.busy, required this.onReconnect});
  final String text;
  final bool busy;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Material(
        color: scheme.error,
        elevation: Elevation.overlay,
        borderRadius: Radii.fullAll,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.sm, Space.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth_disabled_rounded, color: scheme.onError),
              const SizedBox(width: Space.md),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(text, style: theme.textTheme.titleMedium?.copyWith(color: scheme.onError)),
                ),
              ),
              const SizedBox(width: Space.sm),
              TextButton(
                onPressed: busy ? null : onReconnect,
                style: TextButton.styleFrom(
                    foregroundColor: scheme.onError,
                    disabledForegroundColor: scheme.onError.withValues(alpha: 0.6),
                    textStyle: AppType.button(theme.textTheme).copyWith(fontWeight: AppType.heavy)),
                child: Text(busy ? 'Scanning…' : 'Reconnect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Left ankle reconnected" (or a failed rejoin), for a few seconds.
class _NodeToast extends StatelessWidget {
  const _NodeToast({super.key, required this.text, required this.ok});
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (bg, fg) = ok ? (StatusColors.okFill, Colors.white) : (scheme.errorContainer, scheme.onErrorContainer);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Material(
        color: bg,
        elevation: Elevation.overlay,
        borderRadius: Radii.fullAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ok ? Icons.bluetooth_connected_rounded : Icons.error_rounded, color: fg),
              const SizedBox(width: Space.md),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(text, style: theme.textTheme.titleMedium?.copyWith(color: fg)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onBack});
  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_rounded, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: Space.lg),
              Text('Could not start', style: theme.textTheme.heading),
              const SizedBox(height: Space.sm),
              Text(message, textAlign: TextAlign.center, style: theme.textTheme.body),
              const SizedBox(height: Space.xl),
              SizedBox(height: Sizes.button, child: FilledButton(onPressed: onBack, child: const Text('Back'))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live counts, one per verdict, latest attempt per step. Zero stays neutral.
class _Tally extends StatelessWidget {
  const _Tally(this.score);
  final SessionScore score;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      // A tall side panel: one tile per line. A wide strip (phone portrait):
      // four across, number over label. In between (phone landscape): 2 × 2.
      final ratio = c.maxWidth / c.maxHeight;
      final tall = ratio < 0.8, strip = ratio > 3;
      Widget tile(Verdict v) => Expanded(child: _tile(context, v, score.count(v), !strip));
      Widget line(Iterable<Verdict> vs) =>
          Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final v in vs) tile(v)]);
      if (tall) {
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final v in scoredVerdicts) tile(v)]);
      }
      if (strip) return line(scoredVerdicts);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: line(scoredVerdicts.take(2))), Expanded(child: line(scoredVerdicts.skip(2)))],
      );
    });
  }

  /// [row]: number beside the label (side panel), else stacked (phone strip).
  Widget _tile(BuildContext context, Verdict v, int n, bool row) {
    final theme = Theme.of(context);
    final active = n > 0;
    final ink = v.ink(context);
    final color = active ? ink : theme.colorScheme.onSurfaceVariant;
    Widget content(String count, String label) {
      final number = Text(count, style: theme.textTheme.display.copyWith(color: color, height: 1.05));
      final caption = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(v.icon, color: color, size: 20),
          const SizedBox(width: Space.xs),
          Text(label, style: theme.textTheme.cardTitle.copyWith(color: color)),
        ],
      );
      return row
          ? Row(mainAxisSize: MainAxisSize.min, children: [number, const SizedBox(width: Space.md), caption])
          : Column(mainAxisSize: MainAxisSize.min, children: [number, caption]);
    }

    return Semantics(
      label: v.counted(n),
      excludeSemantics: true,
      child: Container(
        margin: const EdgeInsets.all(Space.xs),
        decoration: BoxDecoration(
          color: active ? ink.withValues(alpha: 0.14) : theme.colorScheme.surfaceContainer,
          borderRadius: Radii.mdAll,
        ),
        // Tight constraints, so the FittedBox scales the content up to fill the tile.
        child: FittedBox(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
            child: SizedLike(
              alignment: row ? AlignmentDirectional.centerStart : Alignment.center,
              sizer: content('00', widestVerdictLabel),
              child: content('$n', v.labelFor(n)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Capture mode: a recording indicator and how much each node has sent.
class _CapturePanel extends StatelessWidget {
  const _CapturePanel(this.recorder);
  final SessionRecorder recorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t0 = recorder.t0AppMs;
    final secs = t0 == null ? 0 : max(0, (DateTime.now().millisecondsSinceEpoch - t0) ~/ 1000);
    final red = theme.colorScheme.error;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
            decoration: BoxDecoration(color: red.withValues(alpha: 0.12), borderRadius: Radii.fullAll),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle_rounded, color: red, size: 14),
                const SizedBox(width: Space.sm),
                Text('REC ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
                    style: theme.textTheme.titleLarge?.copyWith(color: red, fontWeight: AppType.heavy)),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          for (final r in Role.values)
            Text(
                '${footName(r)}: ${recorder.sampleCounts[r] ?? 0} samples · '
                '${recorder.events.where((e) => e.foot == r).length} steps',
                style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.sm),
          Text('Recording each node for training.', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Watch first: the step just called, big ("Left: forward"), and the next one.
class _DemoPanel extends StatelessWidget {
  const _DemoPanel({required this.session});
  final DanceSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = session.callout;
    // The chart and the floor map show the steps; the names are left to a
    // screen reader, so the panel does not repeat them.
    String say(List<PresetStep> steps) =>
        steps.map((s) => '${footName(s.foot)}: ${stepLabel(s.stepClass, s.foot)}').join('  ·  ');
    return LayoutBuilder(builder: (context, c) {
      final strip = c.maxWidth / max(1.0, c.maxHeight) > 3;
      return Semantics(
        liveRegion: true,
        label: now.isEmpty ? null : say(now),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: Space.lg, vertical: strip ? Space.sm : Space.lg),
          decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: Radii.mdAll),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: strip ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              StatusPill(icon: Icons.visibility_rounded, text: 'Watch first: not judged', color: scheme.primary),
              if (!strip) ...[
                const SizedBox(height: Space.lg),
                // Fades out where the panel is short (a phone on its side).
                Flexible(
                  child: Text(
                      'Lift as a step crosses the dashed line; land as it reaches the solid line. '
                      'The beat is the landing, as on the floor map.',
                      overflow: TextOverflow.fade,
                      style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }
}
