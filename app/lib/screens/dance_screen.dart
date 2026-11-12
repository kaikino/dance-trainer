import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../audio/beat_clock.dart';
import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../chart/step_chart.dart';
import '../models/preset.dart';
import '../models/session_score.dart';
import '../store/session_store.dart';
import '../ui/style.dart';
import 'preset_screen.dart';
import 'summary_screen.dart';

/// The live screen: music, scrolling step chart, verdicts from the nodes.
/// Sequence on entry: sync clocks → push schedule → start music → send Start(t0) to nodes.
class DanceScreen extends StatefulWidget {
  const DanceScreen({
    super.key,
    required this.manager,
    required this.preset,
    required this.kind,
    required this.dancer,
    this.fromBeat = 1,
  });

  final NodeManager manager;
  final Preset preset;
  final SessionKind kind;
  final String dancer;

  /// Start here instead of beat 1 (a bar start), e.g. to drill one bar.
  final double fromBeat;

  @override
  State<DanceScreen> createState() => _DanceScreenState();
}

enum _Phase { preparing, running, error }

/// Why the music is stopped mid-session, and what the overlay offers. Each
/// carries the bar start that playback resumes from.
sealed class _Hold {
  const _Hold(this.fromBeat);
  final double fromBeat;
}

/// Practice: a mistake, shown for a moment before the rewind.
class _Mistake extends _Hold {
  const _Mistake(this.verdict, this.title, this.detail, super.fromBeat, this.nextTry);
  final Verdict verdict;
  final String title, detail;
  final int nextTry;
}

/// Practice: the bar failed too often; slow down or move on.
class _Choice extends _Hold {
  const _Choice(super.fromBeat);
}

/// The app went to the background or the music was interrupted.
class _Paused extends _Hold {
  const _Paused(this.reason, super.fromBeat);
  final String reason;
}

/// Restarting after a hold failed.
class _Failed extends _Hold {
  const _Failed(this.message, super.fromBeat);
  final String message;
}

class _DanceScreenState extends State<DanceScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// How long a practice mistake stays on screen before the rewind.
  static const _practicePauseTime = Duration(milliseconds: 2500);

  /// Practice "Slow down" plays at this share of the current tempo, down to
  /// [_minTempo] of the routine's own.
  static const _slowDownFactor = 0.8, _minTempo = 0.5;

  late Preset _preset; // at the current tempo
  late BeatClock _clock;
  late final SessionRecorder recorder;
  late final SessionScore score;
  late final StepChartController _chart;
  late final Ticker _ticker;
  final _coach = PracticeCoach();
  final _beatIndex = ValueNotifier<int>(-99); // whole beats, so the header rebuilds once a beat
  final _subs = <StreamSubscription<dynamic>>[];

  _Phase _phase = _Phase.preparing;
  String? _error;
  Future<void>? _recorderBegin;
  bool _ending = false;
  int? _t0AppMs; // beat 1 of the current segment
  _Hold? _hold;

  /// Nodes dancing in this session, and those that dropped out and are not
  /// back yet (the banner, for as long as any is missing).
  final _linked = <Role>{};
  final _missing = <Role>{};
  bool _reconnecting = false;

  /// Short-lived news about a node ("Left ankle reconnected").
  ({String text, bool ok})? _toast;
  Timer? _toastTimer;

  NodeManager get m => widget.manager;

  /// Connected nodes with a synced clock.
  List<NodeClient> get live => m.nodes.where((n) => n.connected && n.offsetUs != null).toList();
  bool get _scoring => widget.kind != SessionKind.capture;
  bool get _practice => widget.kind == SessionKind.practice;
  double get _slowerFactor => max(_minTempo / _preset.tempo, _slowDownFactor);

  @override
  void initState() {
    super.initState();
    _preset = widget.preset;
    _clock = _newClock(_preset);
    score = SessionScore(widget.preset);
    _chart = StepChartController(_preset);
    recorder = SessionRecorder(preset: _preset, dancer: widget.dancer, mode: widget.kind.nodeMode, nodes: m);
    _ticker = createTicker(_onFrame)..start();
    WidgetsBinding.instance.addObserver(this);
    m.addListener(_onNodes);
    _begin();
  }

  BeatClock _newClock(Preset p) =>
      BeatClock(p)..onInterrupted = () => _pause('The music was interrupted by another app or a call.');

  /// Every await is followed by an [_ending] check: End may be pressed at any point.
  Future<void> _begin() async {
    try {
      await _clock.prepare();
      if (_ending) return;
      await (_recorderBegin = recorder.begin());
      if (_ending) return;
      for (final n in m.nodes) {
        // Every node: one that comes back mid-session keeps the same stream.
        _subs.add(n.events.listen((e) => _onEvent(n, e)));
      }
      final from = widget.fromBeat;
      final nodes = m.connectedNodes;
      if (nodes.isEmpty) throw const BleUnavailable('No ankle node is connected. Go back and scan for them.');
      for (final n in nodes) {
        // Always: a node may have rebooted or drifted since the last session.
        await n.syncTime();
        recorder.noteNode(n);
        if (_ending) return;
        await n.pushSchedule(_preset.id, _preset.bpm, _preset.scheduleFor(n.role, fromBeat: from));
        if (_ending) return;
        _linked.add(n.role);
      }
      if (from > 1) score.restart(fromBeat: from);
      final t0 = from > 1 ? await _clock.resumeFrom(from) : await _clock.start();
      if (_ending) return;
      _t0AppMs = t0;
      recorder.addSegment(t0, fromBeat: from, bpm: _preset.bpm);
      setState(() => _phase = _Phase.running);
      for (final n in live) {
        await n.start(widget.kind.nodeMode, t0);
        if (_ending) return;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = '$e';
        });
      }
    }
  }

  void _onFrame(Duration _) {
    final beat = _clock.nowBeat;
    _chart.tick(beat);
    _beatIndex.value = beat.floor();
    if (_phase == _Phase.running && _hold == null && _clock.finished && !_ending) _end();
  }

  // ---- step events -----------------------------------------------------------

  void _onEvent(NodeClient n, StepEvent e) {
    final t0 = _t0AppMs;
    if (!mounted || _ending || !_scoring || _hold != null || t0 == null || n.offsetUs == null) return;
    final beat = 1 + n.msAfter(e.tStrikeNodeUs, t0) / _preset.beatMs;
    final r = score.add(n.role, e, beat);
    if (r.fate == EventFate.duplicate) return;
    final i = r.step;
    if (i != null) _chart.hit(n.role, e.verdict, timingErrMs: e.timingErrMs);
    _chart.setVerdicts(score.shown);
    setState(() {}); // the tally
    if (!_practice || i == null) return;
    final step = score.preset.steps[i];
    switch (_coach.onMistake(e.verdict, step.beat)) {
      case PracticeAction.carryOn:
        break;
      case PracticeAction.rewind:
        _practiceRewind(n.role, e, step);
      case PracticeAction.offerChoice:
        setState(() => _hold = _Choice(Preset.barStart(step.beat)));
        _haltPlayback();
    }
  }

  // ---- holds and restarts ----------------------------------------------------

  /// Stops the music and the nodes; the chart holds where it is.
  Future<void> _haltPlayback() async {
    await _clock.pause();
    for (final n in live) {
      try {
        await n.stop();
      } catch (_) {}
    }
  }

  Future<void> _practiceRewind(Role foot, StepEvent e, PresetStep step) async {
    final barStart = Preset.barStart(step.beat);
    final (title, detail) = switch (e.verdict) {
      Verdict.wrongStep => (
          'Wrong step',
          '${footName(foot)} foot: ${stepLabel(e.stepClass)} instead of ${stepLabel(step.stepClass)}'
        ),
      _ => ('Missed step', '${footName(foot)} foot: ${stepLabel(step.stepClass)}'),
    };
    final hold = _Mistake(e.verdict, title, detail, barStart, _coach.nextTry);
    setState(() => _hold = hold);
    await _haltPlayback();
    await Future<void>.delayed(_practicePauseTime);
    // Ended, or paused meanwhile (then Resume takes over).
    if (!mounted || _ending || _hold != hold) return;
    score.rewind(barStart);
    await _resumeFrom(barStart);
  }

  /// Back to [beat] (a bar start) with a count-in. The nodes get only the
  /// steps from there on, so the replayed count-in is not judged. On failure
  /// the overlay offers Try again and End instead of hanging.
  Future<void> _resumeFrom(double beat) async {
    score.restart(fromBeat: beat);
    _chart.setVerdicts(score.shown);
    try {
      final nodes = live;
      for (final n in nodes) {
        await n.pushSchedule(_preset.id, _preset.bpm, _preset.scheduleFor(n.role, fromBeat: beat));
        if (_ending) return;
      }
      final t0 = await _clock.resumeFrom(beat);
      if (_ending) return;
      _t0AppMs = t0;
      recorder.addSegment(t0, fromBeat: beat, bpm: _preset.bpm);
      if (mounted) setState(() => _hold = null);
      for (final n in nodes) {
        await n.start(widget.kind.nodeMode, t0);
        if (_ending) return;
      }
    } catch (e) {
      if (_ending) return;
      await _haltPlayback();
      if (mounted) setState(() => _hold = _Failed('Could not restart: $e', beat));
    }
  }

  /// Pauses the session (app backgrounded, music interrupted).
  void _pause(String reason) {
    if (_phase != _Phase.running || _ending || !mounted) return;
    final hold = _hold;
    if (hold is _Paused || hold is _Choice || hold is _Failed) return; // already stopped, with its own buttons
    final from = hold?.fromBeat ?? max(score.fromBeat, Preset.barStart(max(1.0, _clock.nowBeat)));
    setState(() => _hold = _Paused(reason, from));
    _haltPlayback();
  }

  Future<void> _slowDown(double fromBeat) async {
    _coach.slowDown();
    final slower = _preset.withTempo(_slowerFactor);
    final clock = _newClock(slower);
    try {
      await clock.prepare();
    } catch (e) {
      clock.dispose();
      if (mounted) setState(() => _hold = _Failed('Could not change the tempo: $e', fromBeat));
      return;
    }
    if (!mounted || _ending) {
      clock.dispose();
      return;
    }
    final old = _clock;
    setState(() {
      _clock = clock;
      _preset = slower;
      _chart.preset = slower;
    });
    old.dispose();
    score.rewind(fromBeat);
    await _resumeFrom(fromBeat);
  }

  Future<void> _keepGoing(double barStart) async {
    _coach.keepGoing();
    final next = barStart + 4;
    if (next > _preset.lastBeat) return _end();
    await _resumeFrom(next);
  }

  // ---- nodes dropping out ----------------------------------------------------

  void _onNodes() {
    if (!mounted || _ending || _phase != _Phase.running) return;
    for (final n in m.nodes) {
      if (_linked.contains(n.role) && !n.connected) {
        _linked.remove(n.role);
        setState(() => _missing.add(n.role));
      } else if (!_linked.contains(n.role) && n.connected && n.status != null) {
        _linked.add(n.role);
        _rejoin(n);
      }
    }
  }

  /// A node came back: sync it and start it from the next bar.
  Future<void> _rejoin(NodeClient n) async {
    final foot = footName(n.role);
    try {
      if (n.offsetUs == null) await n.syncTime();
      recorder.noteNode(n);
      score.forgetSeq(n.role);
      final t0 = _t0AppMs;
      // While held, the next resume starts it with the others.
      if (_hold == null && t0 != null && !_ending) {
        final from = max(score.fromBeat, Preset.barStart(max(1.0, _clock.nowBeat)) + 4);
        await n.pushSchedule(_preset.id, _preset.bpm, _preset.scheduleFor(n.role, fromBeat: from));
        await n.start(widget.kind.nodeMode, t0);
      }
      if (mounted) setState(() => _missing.remove(n.role));
      _showToast('$foot ankle reconnected', ok: true);
    } catch (e) {
      _linked.remove(n.role);
      if (mounted) setState(() => _missing.add(n.role));
      _showToast('$foot ankle could not rejoin', ok: false);
    }
  }

  /// The banner's Reconnect: scan for the missing nodes now instead of
  /// waiting for the automatic retries.
  Future<void> _reconnectNodes() async {
    setState(() => _reconnecting = true);
    try {
      await m.scanAndConnect();
    } on BleUnavailable catch (e) {
      _showToast(e.message, ok: false);
    } catch (e) {
      _showToast('Could not reconnect: $e', ok: false);
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  void _showToast(String text, {required bool ok}) {
    if (!mounted) return;
    _toastTimer?.cancel();
    setState(() => _toast = (text: text, ok: ok));
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pause('The app went to the background.');
    }
  }

  // ---- ending ----------------------------------------------------------------

  Future<void> _stopNodes() async {
    for (final n in m.connectedNodes) {
      try {
        await n.stop();
      } catch (_) {}
    }
  }

  Future<void> _end() async {
    if (_ending) return;
    setState(() => _ending = true);
    await _clock.stop();
    await _stopNodes();
    final begun = await _finishRecording();
    if (!mounted) return;
    if (!begun) {
      // Ended before anything was recorded: nothing to summarise.
      Navigator.pop(context);
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SummaryScreen(
          manager: m,
          preset: _preset,
          kind: widget.kind,
          dancer: widget.dancer,
          recorder: recorder,
          score: score,
        ),
      ),
    );
  }

  /// Waits for the recorder to have begun (if it was started) and ends it.
  Future<bool> _finishRecording() async {
    final b = _recorderBegin;
    if (b == null) return false;
    try {
      await b;
    } catch (_) {
      return false;
    }
    await recorder.end();
    return true;
  }

  Future<void> _confirmEnd() async {
    if (_ending) return;
    if (_phase == _Phase.error || _hold != null) return _end();
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
    if (yes == true) await _end();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    m.removeListener(_onNodes);
    _toastTimer?.cancel();
    _ticker.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    if (!_ending) {
      // Left without End (e.g. the route was removed): never leave the nodes
      // dancing or the recording open.
      _ending = true;
      unawaited(_stopNodes());
      unawaited(_finishRecording());
    }
    _clock.dispose();
    _chart.dispose();
    _beatIndex.dispose();
    super.dispose();
  }

  // ---- layout ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget chart({required bool wide}) => Stack(
          fit: StackFit.expand,
          children: [
            StepChart(
              controller: _chart,
              // Landscape has less height: fewer beats so the footprints stay big.
              beatsVisibleAhead: wide ? 3 : 4,
              beatsVisibleBehind: wide ? 1 : 1.5,
            ),
            ValueListenableBuilder(
              valueListenable: _beatIndex,
              builder: (context, beat, _) {
                // Count-in before beat 1, and again before the bar a restart begins at.
                final now = _clock.nowBeat;
                final countIn = _phase == _Phase.running && _hold == null && now < score.fromBeat
                    ? (score.fromBeat - now).ceil()
                    : 0;
                return countIn > 0 ? _CountIn(countIn) : const SizedBox.shrink();
              },
            ),
            if (_hold case _Paused() || _Failed()) _CentreCard(child: _holdCard(theme)),
            LayoutBuilder(
              builder: (context, c) => Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  // Docked just under the lane header.
                  padding: EdgeInsets.only(top: (c.biggest.shortestSide * 0.08).clamp(40.0, 68.0) + 12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: max(min(c.maxWidth * 0.7, 640), min(c.maxWidth - 16, 340))),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (disconnectedText(_missing) case final text?)
                          _NodeBanner(text: text, busy: _reconnecting, onReconnect: _reconnectNodes),
                        if (_toast case final t?) _NodeToast(text: t.text, ok: t.ok),
                        if (_hold case _Mistake() || _Choice()) _holdCard(theme),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
    final endButton = SizedBox(
      height: 56,
      child: FilledButton.tonalIcon(
        onPressed: _ending ? null : _confirmEnd,
        icon: const Icon(Icons.stop_rounded),
        label: const Text('End session'),
      ),
    );
    final status = ValueListenableBuilder(
      valueListenable: _beatIndex,
      builder: (context, beat, _) => _StatusHeader(
        text: switch (_phase) {
          _Phase.preparing => 'Getting ready…',
          _Phase.error => 'Could not start',
          _ when _hold is _Paused || _hold is _Failed => 'Paused',
          _ when _clock.nowBeat < score.fromBeat => 'Get ready',
          _ => 'Bar ${barOf(_clock.nowBeat).clamp(1, _preset.bars)} of ${_preset.bars}',
        },
        // Dots run through the count-in too (a restart is always at a bar start).
        beatInBar: _phase == _Phase.running && _hold == null ? (beat - 1) % 4 : null,
      ),
    );
    final side = _scoring
        ? _Tally(score)
        : ValueListenableBuilder(
            valueListenable: _beatIndex, builder: (context, beat, child) => _CapturePanel(recorder));

    final body = _phase == _Phase.error
        ? _ErrorPanel(message: _error ?? '', onBack: _end)
        : LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth > c.maxHeight * 1.2) {
                // Landscape tablet: chart takes the full height, status and tally at the side.
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                        child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 8, 16), child: chart(wide: true))),
                    SizedBox(
                      width: (c.maxWidth * 0.3).clamp(280.0, 420.0),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 24, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            status,
                            const SizedBox(height: 12),
                            Expanded(child: side),
                            const SizedBox(height: 16),
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
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: status),
                  Expanded(
                      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: chart(wide: false))),
                  Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), child: SizedBox(height: 96, child: side)),
                  Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: endButton),
                ],
              );
            },
          );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmEnd();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_preset.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  StatusPill(icon: Icons.speed_rounded, text: '${_preset.bpm.round()} bpm'),
                  // On a phone the routine name needs the room.
                  if (MediaQuery.sizeOf(context).width >= 600)
                    StatusPill(icon: widget.kind.icon, text: widget.kind.title, color: theme.colorScheme.primary),
                ],
              ),
            ),
          ],
        ),
        body: body,
      ),
    );
  }

  /// The overlay card for the current hold.
  Widget _holdCard(ThemeData theme) {
    final hold = _hold!;
    final bar = barOf(hold.fromBeat);
    return switch (hold) {
      _Mistake() => _HoldCard(
          color: hold.verdict.ink(context),
          icon: hold.verdict.icon,
          title: hold.title,
          detail: hold.detail,
          chips: ['Again from bar $bar', 'Try ${hold.nextTry} of ${PracticeCoach.maxTries}'],
        ),
      _Choice() => _HoldCard(
          color: Verdict.offBeat.ink(context),
          icon: Icons.replay_rounded,
          title: 'Bar $bar is a tricky one',
          detail: '${PracticeCoach.maxTries} tries without getting it. Slow it down, or move on and come back to it.',
          actions: [
            if (_preset.tempo > _minTempo + 0.01)
              FilledButton.icon(
                onPressed: () => _slowDown(hold.fromBeat),
                icon: const Icon(Icons.slow_motion_video_rounded),
                label: Text('Slow down to ${(_preset.bpm * _slowerFactor).round()} bpm'),
              ),
            OutlinedButton.icon(
              onPressed: () => _keepGoing(hold.fromBeat),
              icon: const Icon(Icons.skip_next_rounded),
              label: const Text('Keep going'),
            ),
          ],
        ),
      _Paused() => _HoldCard(
          color: theme.colorScheme.primary,
          icon: Icons.pause_circle_rounded,
          title: 'Paused',
          detail: '${hold.reason} Resume picks up from bar $bar with a count-in.',
          actions: [
            FilledButton.icon(
              onPressed: () => _resumeFrom(hold.fromBeat),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Resume'),
            ),
            OutlinedButton(onPressed: _end, child: const Text('End session')),
          ],
        ),
      _Failed() => _HoldCard(
          color: theme.colorScheme.error,
          icon: Icons.error_rounded,
          title: 'Something went wrong',
          detail: hold.message,
          actions: [
            FilledButton.icon(
              onPressed: () => _resumeFrom(hold.fromBeat),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
            OutlinedButton(onPressed: _end, child: const Text('End session')),
          ],
        ),
    };
  }
}

/// Bar counter and four beat dots, at a fixed height so the chart below never jumps.
class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.text, required this.beatInBar});
  final String text;
  final int? beatInBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          Expanded(
            // Shrinks rather than cuts "Bar 12 of 16" in a narrow side panel or at large text.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(text, maxLines: 1, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
          ),
          Semantics(
            label: beatInBar == null ? null : 'beat ${beatInBar! + 1} of 4',
            excludeSemantics: true,
            child: Row(
              children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.only(left: 8),
                    alignment: Alignment.center,
                    child: Container(
                      width: beatInBar == i ? 22 : 14,
                      height: beatInBar == i ? 22 : 14,
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
          borderRadius: BorderRadius.circular(20),
        ),
        child: LayoutBuilder(
          builder: (context, c) => Center(
            child: Text('$n',
                style: TextStyle(
                    fontSize: c.biggest.shortestSide * 0.45,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                    height: 1)),
          ),
        ),
      ),
    );
  }
}

/// A card centred over a dimmed chart (Paused, errors).
class _CentreCard extends StatelessWidget {
  const _CentreCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
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
  });
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
      // As wide as its text needs (up to the dock's width), not always the full width.
      return IntrinsicWidth(
          child: Material(
        elevation: 8,
        shadowColor: Colors.black38,
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 10, color: color),
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
                                  style: TextStyle(
                                      fontSize: size, fontWeight: FontWeight.w800, color: color, height: 1.1)),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: size * 0.3),
                      Text(detail,
                          style: TextStyle(fontSize: size * 0.62, color: theme.colorScheme.onSurface, height: 1.3)),
                      if (chips.isNotEmpty) ...[
                        SizedBox(height: size * 0.45),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final t in chips)
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: size * 0.45, vertical: size * 0.15),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(t,
                                    style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.w700, color: color)),
                              ),
                          ],
                        ),
                      ],
                      if (actions.isNotEmpty) ...[
                        SizedBox(height: size * 0.6),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [for (final a in actions) SizedBox(height: 52, child: a)],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
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
  const _NodeBanner({required this.text, required this.busy, required this.onReconnect});
  final String text;
  final bool busy;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.error,
        elevation: 4,
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth_disabled_rounded, color: scheme.onError),
              const SizedBox(width: 10),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(text,
                      style: TextStyle(color: scheme.onError, fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : onReconnect,
                style: TextButton.styleFrom(
                    foregroundColor: scheme.onError,
                    disabledForegroundColor: scheme.onError.withValues(alpha: 0.6),
                    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
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
  const _NodeToast({required this.text, required this.ok});
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = ok ? (Verdict.correct.fill, Colors.white) : (scheme.errorContainer, scheme.onErrorContainer);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: bg,
        elevation: 4,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ok ? Icons.bluetooth_connected_rounded : Icons.error_outline_rounded, color: fg),
              const SizedBox(width: 10),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(text, style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w700)),
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
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text('Could not start', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 24),
              SizedBox(height: 52, child: FilledButton(onPressed: onBack, child: const Text('Back'))),
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
      final number = Text(count,
          style: theme.textTheme.displaySmall?.copyWith(color: color, fontWeight: FontWeight.w800, height: 1.05));
      final caption = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(v.icon, color: color, size: 20),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      );
      return row
          ? Row(mainAxisSize: MainAxisSize.min, children: [number, const SizedBox(width: 14), caption])
          : Column(mainAxisSize: MainAxisSize.min, children: [number, caption]);
    }

    return Semantics(
      label: '$n ${v.label}',
      excludeSemantics: true,
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: active ? ink.withValues(alpha: 0.14) : theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        // Tight constraints, so the FittedBox scales the content up to fill the tile.
        child: FittedBox(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SizedLike(
              alignment: row ? AlignmentDirectional.centerStart : Alignment.center,
              sizer: content('00', widestVerdict.label),
              child: content('$n', v.label),
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: red.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: red, size: 14),
                const SizedBox(width: 8),
                Text('REC ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
                    style: TextStyle(color: red, fontWeight: FontWeight.w800, fontSize: 20)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final r in Role.values)
            Text(
                '${footName(r)}: ${recorder.sampleCounts[r] ?? 0} samples · '
                '${recorder.events.where((e) => e.foot == r).length} steps',
                style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Recording each node for training.', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
