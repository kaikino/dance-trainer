import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../chart/floor_map.dart';
import '../chart/step_chart.dart';
import '../models/preset.dart';
import '../models/session_kind.dart';
import '../models/session_score.dart';
import '../ui/step_legend.dart';
import '../ui/screen_awake.dart';
import '../ui/style.dart';
import 'dance/dance_session.dart';
import 'summary_screen.dart';

part 'dance/widgets.dart';

/// The live screen: music, scrolling step chart, verdicts from the nodes.
/// The session logic lives in [DanceSession]; this draws it and gives it
/// frames, app lifecycle and navigation.
class DanceScreen extends StatefulWidget {
  const DanceScreen({
    super.key,
    required this.manager,
    required this.preset,
    required this.kind,
    required this.dancer,
    this.fromBeat = 1,
    this.demo = false,
  });

  final NodeManager manager;
  final Preset preset;
  final SessionKind kind;
  final String dancer;

  /// Start here instead of beat 1 (a bar start), e.g. to drill one bar.
  final double fromBeat;

  /// Watch first: no nodes, no judging, no recording.
  final bool demo;

  @override
  State<DanceScreen> createState() => _DanceScreenState();
}

class _DanceScreenState extends State<DanceScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final DanceSession s;
  late final Ticker _ticker;
  final _beatIndex = ValueNotifier<int>(-99); // whole beats, so the header rebuilds once a beat
  bool _floor = true; // the floor map beside (or above) the chart

  @override
  void initState() {
    super.initState();
    ScreenAwake.on(); // no auto-lock mid-routine
    s = DanceSession(
      manager: widget.manager,
      preset: widget.preset,
      kind: widget.kind,
      dancer: widget.dancer,
      fromBeat: widget.fromBeat,
      demo: widget.demo,
    )
      ..onEnded = _onEnded
      ..addListener(_onSession);
    _ticker = createTicker(_onFrame)..start();
    WidgetsBinding.instance.addObserver(this);
    s.begin();
  }

  void _onFrame(Duration _) {
    _beatIndex.value = s.tick().floor();
    // Nothing moves while the music is held: no frames until it plays again.
    if (!s.needsFrames) _ticker.stop();
  }

  void _onSession() {
    if (!mounted) return;
    if (s.needsFrames && !_ticker.isActive) _ticker.start();
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      s.pause('The app went to the background.');
    }
  }

  void _onEnded(bool recorded) {
    if (!mounted) return;
    if (!recorded) {
      // Watch first, or ended before anything was recorded: nothing to summarise.
      Navigator.pop(context);
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SummaryScreen(
          manager: widget.manager,
          preset: s.preset,
          kind: widget.kind,
          dancer: widget.dancer,
          recorder: s.recorder,
          score: s.score,
        ),
      ),
    );
  }

  Future<void> _confirmEnd() async {
    if (s.ending) return;
    if (s.demo || s.phase == SessionPhase.error || s.hold != null) return s.end();
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End session?'),
        content: const Text('The music stops and the session is saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep dancing')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('End session')),
        ],
      ),
    );
    if (yes == true) await s.end();
  }

  @override
  void dispose() {
    ScreenAwake.off();
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    s.removeListener(_onSession);
    s.dispose();
    _beatIndex.dispose();
    super.dispose();
  }

  // ---- layout ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hold = s.hold;
    Widget chart({required bool wide}) => Stack(
          fit: StackFit.expand,
          children: [
            StepChart(
              controller: s.chart,
              // Landscape has less height: fewer beats so the footprints stay big.
              beatsVisibleAhead: wide ? 3 : 4,
              beatsVisibleBehind: wide ? 1 : 1.5,
            ),
            ValueListenableBuilder(
              valueListenable: _beatIndex,
              builder: (context, beat, _) {
                // Count-in before beat 1, and again before the bar a restart begins at.
                final now = s.clock.nowBeat;
                final from = s.score.fromBeat;
                final countIn =
                    s.phase == SessionPhase.running && s.hold == null && now < from ? (from - now).ceil() : 0;
                return countIn > 0 ? _CountIn(countIn) : const SizedBox.shrink();
              },
            ),
            AnimatedSwitcher(
              duration: Motion.fade,
              child: hold is PausedHold || hold is FailedHold
                  ? _CentreCard(key: ValueKey(hold), child: _holdCard(theme))
                  : const SizedBox.shrink(),
            ),
            LayoutBuilder(
              builder: (context, c) => Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  // Docked just under the lane header.
                  padding: EdgeInsets.only(top: StepChart.headerHeight(c.biggest) + Space.md),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: max(min(c.maxWidth * 0.7, 640), min(c.maxWidth - 16, 340))),
                    child: AnimatedSize(
                      duration: Motion.fade,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: Motion.fade,
                            child: switch (disconnectedText(s.missing)) {
                              final text? => _NodeBanner(
                                  key: ValueKey(text), text: text, busy: s.reconnecting, onReconnect: s.reconnectNodes),
                              null => const SizedBox.shrink(),
                            },
                          ),
                          AnimatedSwitcher(
                            duration: Motion.fade,
                            child: switch (s.toast) {
                              final t? => _NodeToast(key: ValueKey(t), text: t.text, ok: t.ok),
                              null => const SizedBox.shrink(),
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
    // Practice coaching floats at the bottom, over the steps already danced.
    final coaching = hold != null && hold.coaching ? _holdCard(theme) : null;
    // The paused or failed card over the chart offers End itself.
    final covered = hold is PausedHold || hold is FailedHold;
    final hud = ValueListenableBuilder(
      valueListenable: _beatIndex,
      builder: (context, beat, _) {
        final practice = s.kind == SessionKind.practice;
        final acc = practice ? s.score.firstTryAccuracy : s.score.accuracy;
        return _Hud(
          // Dots run through the count-in too (a restart is always at a bar start).
          beatInBar: s.phase == SessionPhase.running && hold == null ? (beat - 1) % s.preset.beatsPerBar : null,
          beatsPerBar: s.preset.beatsPerBar,
          score: s.scoring && !s.demo && s.phase == SessionPhase.running,
          rec: !s.scoring && !s.demo,
          text: switch (s.phase) {
            SessionPhase.preparing => 'Getting ready…',
            _ when s.demo => 'Watching',
            _ when !s.scoring => 'Rec',
            _ => acc == null ? '–' : '${(acc * 100).round()}%',
          },
        );
      },
    );

    // Where the feet go, from the routine (not the sensors): a reference.
    final floor = FloorMap(preset: s.preset, beat: () => s.chart.nowBeat, repaint: s.chart, caption: false);

    final body = s.phase == SessionPhase.error
        ? _ErrorPanel(message: s.error ?? '', onBack: s.end)
        : LayoutBuilder(
            builder: (context, c) {
              final Widget stage;
              if (c.maxWidth > c.maxHeight * 1.2) {
                // On its side: the chart and the floor map share the whole width
                // (a phone shares it half and half), the chart alone if the map is off.
                final phone = c.maxHeight < 500;
                stage = Padding(
                  padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, Space.lg),
                  child: _floor && c.maxWidth >= (phone ? 480 : 720)
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: phone ? 1 : 5, child: chart(wide: true)),
                            const SizedBox(width: Space.md),
                            Expanded(flex: phone ? 1 : 4, child: floor),
                          ],
                        )
                      : chart(wide: true),
                );
              } else {
                stage = Padding(
                  padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_floor) ...[
                        SizedBox(height: c.maxHeight * 0.32, child: floor),
                        const SizedBox(height: Space.sm),
                      ],
                      Expanded(child: chart(wide: false)),
                    ],
                  ),
                );
              }
              return Stack(
                children: [
                  Positioned.fill(child: stage),
                  Positioned(
                    left: Space.lg,
                    right: Space.lg,
                    bottom: Space.xl,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: AnimatedSwitcher(
                          duration: Motion.fade,
                          child: coaching == null
                              ? const SizedBox.shrink()
                              : Material(
                                  key: ValueKey(hold),
                                  color: Colors.transparent,
                                  elevation: Elevation.overlay,
                                  child: coaching,
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );

    final paused = hold != null && !hold.coaching;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmEnd();
      },
      child: Scaffold(
        appBar: AppBar(
          title: hud,
          actions: [
            IconButton(
              onPressed: () => setState(() => _floor = !_floor),
              isSelected: _floor,
              icon: const Icon(Icons.grid_view_rounded),
              tooltip: _floor ? 'Hide the floor map' : 'Show the floor map',
            ),
            // The legend while there is time to read it: watching, or paused.
            if (s.demo || paused)
              IconButton(
                onPressed: () {
                  // The music waits while the legend is read.
                  if (s.hold == null) s.pause('Paused to read the steps.');
                  showStepLegend(context);
                },
                icon: const Icon(Icons.info_outline_rounded),
                tooltip: 'What the steps mean',
              ),
            TextButton(
              onPressed: s.ending || covered ? null : _confirmEnd,
              child: Text(s.demo ? 'Stop' : 'End'),
            ),
            const SizedBox(width: Space.sm),
          ],
        ),
        body: body,
      ),
    );
  }

  /// The card for the current hold. [fill]: as wide as its slot (beside or
  /// under the chart) rather than as wide as its text.
  Widget _holdCard(ThemeData theme, {bool fill = false}) {
    final hold = s.hold!;
    final bar = barOf(hold.fromBeat, s.preset.beatsPerBar);
    return switch (hold) {
      MistakeHold() => _HoldCard(
          fill: fill,
          color: hold.verdict.ink(context),
          icon: hold.verdict.icon,
          title: hold.title,
          detail: hold.detail,
          chips: ['Again from bar $bar', 'Try ${hold.nextTry} of ${PracticeCoach.maxTries}'],
        ),
      ChoiceHold() => _HoldCard(
          fill: fill,
          color: StatusColors.warn(context),
          icon: Icons.replay_rounded,
          title: 'Bar $bar is a tricky one',
          detail: '${PracticeCoach.maxTries} tries without getting it. Slow it down, or move on and come back to it.',
          actions: [
            if (s.canSlowDown)
              FilledButton.icon(
                onPressed: () => s.slowDown(hold.fromBeat),
                icon: const Icon(Icons.slow_motion_video_rounded),
                label: Text('Slow down to ${(s.preset.bpm * s.slowerFactor).round()} bpm'),
              ),
            OutlinedButton.icon(
              onPressed: () => s.keepGoing(hold.fromBeat),
              icon: const Icon(Icons.skip_next_rounded),
              label: const Text('Keep going'),
            ),
          ],
        ),
      PausedHold() => _HoldCard(
          color: theme.colorScheme.primary,
          icon: Icons.pause_circle_rounded,
          title: 'Paused',
          detail: '${hold.reason} Resume picks up from bar $bar with a count-in.',
          actions: [
            FilledButton.icon(
              onPressed: () => s.resumeFrom(hold.fromBeat),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Resume'),
            ),
            OutlinedButton(onPressed: s.end, child: Text(s.demo ? 'Stop watching' : 'End session')),
          ],
        ),
      FailedHold() => _HoldCard(
          color: theme.colorScheme.error,
          icon: Icons.error_rounded,
          title: 'Something went wrong',
          detail: hold.message,
          actions: [
            FilledButton.icon(
              onPressed: () => s.resumeFrom(hold.fromBeat),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
            OutlinedButton(onPressed: s.end, child: const Text('End session')),
          ],
        ),
    };
  }
}
