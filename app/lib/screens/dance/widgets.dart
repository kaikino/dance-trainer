part of '../dance_screen.dart';

/// The only status while dancing, in the top bar: the beat in the bar as dots
/// and, beside them, the running accuracy (or what the session is doing when
/// it is not scored: watching, recording, getting ready).
class _Hud extends StatelessWidget {
  const _Hud(
      {required this.beatInBar, required this.beatsPerBar, required this.text, this.score = false, this.rec = false});
  final int? beatInBar;
  final int beatsPerBar;
  final String text;

  /// [text] is the accuracy: large, in the accent colour.
  final bool score;

  /// A red dot before [text]: recording.
  final bool rec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const big = 18.0, small = 10.0;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: beatInBar == null ? null : 'beat ${beatInBar! + 1} of $beatsPerBar',
            excludeSemantics: true,
            child: Row(
              children: [
                for (var i = 0; i < beatsPerBar; i++)
                  Container(
                    width: big,
                    height: big,
                    margin: EdgeInsets.only(left: i == 0 ? 0 : Space.sm),
                    alignment: Alignment.center,
                    child: Container(
                      width: beatInBar == i ? big : small,
                      height: beatInBar == i ? big : small,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: beatInBar == i ? scheme.primary : scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Space.lg),
          if (rec) ...[
            Container(width: 10, height: 10, decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle)),
            const SizedBox(width: Space.sm),
          ],
          Semantics(
            label: score ? 'Accuracy $text' : null,
            child: Text(
              text,
              style: score
                  ? theme.textTheme.headlineMedium?.copyWith(color: scheme.primary, height: 1)
                  : theme.textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
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
