import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../chart/step_chart.dart';
import '../models/preset.dart';
import '../models/session_kind.dart';
import '../models/session_score.dart';
import '../store/session_store.dart';
import '../ui/step_legend.dart';
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

  @override
  void initState() {
    super.initState();
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
    // Practice coaching sits beside the chart (landscape) or under it
    // (portrait), never over the steps coming up.
    final coaching = hold != null && hold.coaching ? _holdCard(theme, fill: true) : null;
    // Hidden (its room kept, so the chart does not jump) while the paused or
    // failed card offers End itself.
    final covered = hold is PausedHold || hold is FailedHold;
    final endButton = Visibility.maintain(
      visible: !covered,
      child: SizedBox(
        height: Sizes.button,
        child: FilledButton.tonalIcon(
          onPressed: s.ending || covered ? null : _confirmEnd,
          icon: Icon(s.demo ? Icons.close_rounded : Icons.stop_rounded),
          label: Text(s.demo ? 'Stop watching' : 'End session'),
        ),
      ),
    );
    final status = ValueListenableBuilder(
      valueListenable: _beatIndex,
      builder: (context, beat, _) => _StatusHeader(
        text: switch (s.phase) {
          SessionPhase.preparing => 'Getting ready…',
          SessionPhase.error => 'Could not start',
          // The card over the chart says Paused; here, where it picks up.
          _ when hold is PausedHold || hold is FailedHold => 'Bar ${barOf(hold!.fromBeat, s.preset.beatsPerBar)} of ${s.preset.bars}',
          _ when s.clock.nowBeat < s.score.fromBeat => 'Get ready',
          _ => 'Bar ${barOf(s.clock.nowBeat, s.preset.beatsPerBar).clamp(1, s.preset.bars)} of ${s.preset.bars}',
        },
        // Dots run through the count-in too (a restart is always at a bar start).
        beatInBar: s.phase == SessionPhase.running && hold == null ? (beat - 1) % s.preset.beatsPerBar : null,
        beatsPerBar: s.preset.beatsPerBar,
      ),
    );
    final Widget side = s.demo
        ? _DemoPanel(session: s)
        : s.scoring
            ? _Tally(s.score)
            : ValueListenableBuilder(
                valueListenable: _beatIndex, builder: (context, beat, child) => _CapturePanel(s.recorder));

    final body = s.phase == SessionPhase.error
        ? _ErrorPanel(message: s.error ?? '', onBack: s.end)
        : LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth > c.maxHeight * 1.2) {
                // Landscape tablet: chart takes the full height, status and tally at the side.
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                        child: Padding(
                            padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.sm, Space.lg),
                            child: chart(wide: true))),
                    SizedBox(
                      width: (c.maxWidth * 0.3).clamp(280.0, 420.0),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.xl, Space.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            status,
                            const SizedBox(height: Space.md),
                            AnimatedSize(
                              duration: Motion.fade,
                              alignment: Alignment.topCenter,
                              child: AnimatedSwitcher(
                                duration: Motion.fade,
                                child: coaching == null
                                    ? const SizedBox(width: double.infinity)
                                    : Padding(
                                        key: ValueKey(hold),
                                        padding: const EdgeInsets.only(bottom: Space.md),
                                        child: coaching),
                              ),
                            ),
                            Expanded(child: side),
                            const SizedBox(height: Space.lg),
                            endButton,
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(padding: const EdgeInsets.symmetric(horizontal: Space.lg), child: status),
                  Expanded(
                      child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Space.md), child: chart(wide: false))),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
                    child: AnimatedSize(
                      duration: Motion.fade,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: Motion.fade,
                        child: coaching == null
                            ? SizedBox(key: const ValueKey('side'), height: 96, child: side)
                            : KeyedSubtree(key: ValueKey(hold), child: coaching),
                      ),
                    ),
                  ),
                  Padding(padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg), child: endButton),
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
          title: Text(s.preset.name),
          actions: [
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
            Padding(
              padding: const EdgeInsets.only(right: Space.lg),
              child: Wrap(
                spacing: Space.sm,
                children: [
                  StatusPill(icon: Icons.speed_rounded, text: '${s.preset.bpm.round()} bpm'),
                  // On a phone the routine name needs the room.
                  if (MediaQuery.sizeOf(context).width >= 600)
                    s.demo
                        ? StatusPill(
                            icon: Icons.visibility_rounded, text: 'Watch first', color: theme.colorScheme.primary)
                        : StatusPill(icon: widget.kind.icon, text: widget.kind.title, color: theme.colorScheme.primary),
                ],
              ),
            ),
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
