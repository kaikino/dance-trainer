import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chart/floor_map.dart';
import '../models/preset.dart';
import 'style.dart';

/// The song select: one routine large in the middle, its neighbours smaller
/// and dimmed to the left and right. Swipe (or tap a neighbour) to move;
/// [onChanged] reports the routine now in the middle.
class SongCarousel extends StatefulWidget {
  const SongCarousel({
    super.key,
    required this.presets,
    required this.index,
    required this.onChanged,
    required this.onHistory,
    this.best = const {},
    this.sessions = const {},
    this.tempo = 1.0,
    this.height = 340,
  });

  final List<Preset> presets;
  final int index;
  final ValueChanged<int> onChanged;
  final ValueChanged<Preset> onHistory;

  /// Best score and number of sessions, by preset id.
  final Map<int, double> best;
  final Map<int, int> sessions;

  /// The chosen tempo: the middle card's floor map steps at it.
  final double tempo;
  final double height;

  @override
  State<SongCarousel> createState() => _SongCarouselState();
}

class _SongCarouselState extends State<SongCarousel> {
  PageController? _pc;
  double _fraction = 0;

  @override
  void didUpdateWidget(SongCarousel old) {
    super.didUpdateWidget(old);
    final pc = _pc;
    if (pc != null && pc.hasClients && widget.index != (pc.page ?? pc.initialPage).round()) {
      pc.animateToPage(widget.index, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _pc?.dispose();
    super.dispose();
  }

  PageController _controller(double fraction) {
    final pc = _pc;
    if (pc != null && (fraction - _fraction).abs() < 0.005) return pc;
    final page = pc != null && pc.hasClients ? (pc.page ?? widget.index.toDouble()).round() : widget.index;
    if (pc != null) WidgetsBinding.instance.addPostFrameCallback((_) => pc.dispose());
    _fraction = fraction;
    return _pc = PageController(viewportFraction: fraction, initialPage: page);
  }

  void _go(int i) {
    if (i < 0 || i >= widget.presets.length) return;
    _pc?.animateToPage(i, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.presets.length;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final phone = c.maxWidth < 600;
      final cardW = (c.maxWidth * (phone ? 0.68 : 0.34)).clamp(220.0, 380.0);
      final pc = _controller(min(1.0, cardW / c.maxWidth));
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: widget.height,
            child: Stack(
              children: [
                PageView.builder(
                  controller: pc,
                  itemCount: n,
                  clipBehavior: Clip.none,
                  onPageChanged: (i) {
                    HapticFeedback.selectionClick();
                    widget.onChanged(i);
                  },
                  itemBuilder: (context, i) => AnimatedBuilder(
                    animation: pc,
                    builder: (context, _) {
                      final page = pc.hasClients && pc.position.haveDimensions ? pc.page! : widget.index.toDouble();
                      final d = (page - i).abs().clamp(0.0, 1.0);
                      final p = widget.presets[i];
                      return Transform.scale(
                        scale: 1 - 0.14 * d,
                        child: Opacity(
                          opacity: 1 - 0.5 * d,
                          child: SongCard(
                            preset: p,
                            focus: 1 - d,
                            tempo: widget.tempo,
                            best: widget.best[p.id],
                            sessions: widget.sessions[p.id] ?? 0,
                            onTap: d > 0.5 ? () => _go(i) : null,
                            onHistory: () => widget.onHistory(p),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < n; i++)
                AnimatedContainer(
                  duration: Motion.fade,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == widget.index ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == widget.index ? scheme.primary : Stage.line,
                    borderRadius: Radii.fullAll,
                  ),
                ),
            ],
          ),
        ],
      );
    });
  }
}

/// One routine: where its feet go on the floor (stepping, in the middle
/// card), its name, tempo, time signature and length, and the best score.
class SongCard extends StatelessWidget {
  const SongCard({
    super.key,
    required this.preset,
    required this.focus,
    required this.onHistory,
    this.tempo = 1.0,
    this.best,
    this.sessions = 0,
    this.onTap,
  });

  final Preset preset;

  /// 1 in the middle, 0 at the side.
  final double focus;
  final double tempo;
  final double? best;
  final int sessions;
  final VoidCallback? onTap;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final b = best;
    final seconds = (preset.lastBeat * preset.beatMs / 1000).round();
    final middle = focus > 0.5;
    return Semantics(
      selected: middle,
      button: onTap != null,
      label: preset.name,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.md),
          decoration: BoxDecoration(
            color: Stage.panel,
            borderRadius: Radii.lgAll,
            border: Border.all(color: Color.lerp(Stage.panel, scheme.primary, focus)!, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The routine on the floor: stepping in the middle card, at rest beside it.
                Expanded(
                  child: middle
                      ? FloorMapPreview(preset: preset, tempo: tempo, caption: false)
                      : FloorMap(preset: preset, beat: () => 0.5, caption: false),
                ),
                const SizedBox(height: Space.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(preset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.headlineSmall?.copyWith(height: 1.1)),
                      const SizedBox(height: 2),
                      Text('${preset.bpm.round()} BPM · ${preset.beatsPerBar}/4 · ${preset.bars} bars · $seconds s',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                SizedBox(
                  height: 40,
                  child: Padding(
                    padding: const EdgeInsets.only(left: Space.xs),
                    child: Row(
                      children: [
                        if (b != null)
                          Text('Best ${(b * 100).round()}%', style: text.titleSmall?.copyWith(color: scheme.primary)),
                        const Spacer(),
                        if (sessions > 0 && middle) TextButton(onPressed: onHistory, child: const Text('History')),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
