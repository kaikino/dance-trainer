import 'dart:async';

import 'package:flutter/material.dart';

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
  });

  final NodeManager manager;
  final Preset preset;
  final SessionKind kind;
  final String dancer;

  @override
  State<DanceScreen> createState() => _DanceScreenState();
}

enum _Phase { preparing, running, error }

class _DanceScreenState extends State<DanceScreen> {
  /// How long a practice mistake stays on screen before the rewind.
  static const _practicePauseTime = Duration(milliseconds: 2500);

  late final BeatClock clock;
  late final SessionRecorder recorder;
  late final SessionScore score;
  final _subs = <StreamSubscription<dynamic>>[];
  _Phase _phase = _Phase.preparing;
  String? _error;
  Future<void>? _recorderBegin;
  bool _paused = false;
  bool _ending = false;
  int? _t0AppMs; // beat 1 of the current segment
  ({String title, String detail})? _practiceNote;

  Preset get preset => widget.preset;
  NodeManager get m => widget.manager;
  List<NodeClient> get live => m.nodes.where((n) => n.connected).toList();
  bool get _scoring => widget.kind != SessionKind.capture;

  @override
  void initState() {
    super.initState();
    clock = BeatClock(preset);
    score = SessionScore(preset);
    recorder = SessionRecorder(preset: preset, dancer: widget.dancer, mode: widget.kind.nodeMode, nodes: m);
    clock.addListener(_tick);
    _begin();
  }

  /// Every await is followed by an [_ending] check: End may be pressed at any point.
  Future<void> _begin() async {
    try {
      await clock.prepare();
      if (_ending) return;
      await (_recorderBegin = recorder.begin());
      if (_ending) return;
      for (final n in live) {
        // Always: a node may have rebooted or drifted since the last session.
        await n.syncTime();
        if (_ending) return;
        await n.pushSchedule(preset.id, preset.bpm, preset.scheduleFor(n.role));
        if (_ending) return;
        _subs.add(n.events.listen((e) => _onEvent(n, e)));
      }
      final t0 = await clock.start();
      if (_ending) return;
      _t0AppMs = t0;
      recorder.addSegment(t0);
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

  void _tick() {
    if (!mounted) return;
    if (clock.finished && !_ending) {
      _end();
      return;
    }
    setState(() {});
  }

  void _onEvent(NodeClient n, StepEvent e) {
    final t0 = _t0AppMs, offset = n.offsetUs;
    if (!mounted || _ending || !_scoring || t0 == null || offset == null) return;
    final msAfterT0 = (e.tStrikeNodeUs - offset) / 1000.0 - t0;
    final r = score.add(n.role, e, msAfterT0);
    if (r.fate == EventFate.duplicate) return;
    setState(() {});
    final i = r.step;
    final mistake = const {Verdict.wrongStep, Verdict.missed, Verdict.offBeat}.contains(e.verdict);
    if (widget.kind == SessionKind.practice && mistake && !_paused && i != null) {
      _practicePause(n.role, e, preset.steps[i]);
    }
  }

  Future<void> _stopNodes() async {
    for (final n in live) {
      try {
        await n.stop();
      } catch (_) {}
    }
  }

  Future<void> _practicePause(Role foot, StepEvent e, PresetStep step) async {
    _paused = true;
    final barStart = Preset.barStart(step.beat);
    final what = switch (e.verdict) {
      Verdict.wrongStep => '${stepLabel(e.stepClass)} instead of ${stepLabel(step.stepClass)}',
      Verdict.missed => 'missed the ${stepLabel(step.stepClass)} step',
      _ => '${e.timingErrMs > 0 ? 'late' : 'early'} by ${e.timingErrMs.abs()} ms',
    };
    setState(() => _practiceNote = (
          title: '${footName(foot)} foot: $what',
          detail: 'Again from bar ${(barStart - 1) ~/ 4 + 1}',
        ));
    await clock.pause();
    if (_ending) return;
    await _stopNodes();
    if (_ending) return;
    await Future<void>.delayed(_practicePauseTime);
    if (!mounted || _ending) return;

    // Back to the start of the bar this step is in, with a count-in. The nodes
    // get only the steps from there on, so the replayed count-in is not judged.
    score.rewind(barStart);
    for (final c in live) {
      await c.pushSchedule(preset.id, preset.bpm, preset.scheduleFor(c.role, fromBeat: barStart));
      if (_ending) return;
    }
    final t0 = await clock.resumeFrom(barStart);
    if (_ending) return;
    _t0AppMs = t0;
    recorder.addSegment(t0, fromBeat: barStart);
    for (final c in live) {
      await c.start(Mode.dance, t0);
      if (_ending) return;
    }
    if (!mounted) return;
    setState(() {
      _practiceNote = null;
      _paused = false;
    });
  }

  Future<void> _end() async {
    if (_ending) return;
    setState(() => _ending = true);
    await clock.stop();
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
          preset: preset,
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
    if (_phase == _Phase.error) return _end();
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
    clock.removeListener(_tick);
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final beat = clock.nowBeat;
    // Count-in before beat 1, and again before the bar a rewind restarts from.
    final countIn = _phase == _Phase.running && !_paused && beat < score.fromBeat ? (score.fromBeat - beat).ceil() : 0;
    // Landscape has less height: show fewer beats so the footprints stay big.
    Widget chart({required bool wide}) => Stack(
          fit: StackFit.expand,
          children: [
            StepChart(
              preset: preset,
              nowBeat: beat,
              verdicts: Map.unmodifiable(score.shown),
              beatsVisibleAhead: wide ? 3 : 4,
              beatsVisibleBehind: wide ? 1 : 1.5,
            ),
            if (countIn > 0) _CountIn(countIn),
            if (_practiceNote case final note?) _PracticeBanner(title: note.title, detail: note.detail),
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
    final status = _StatusHeader(
      text: switch (_phase) {
        _Phase.preparing => 'Getting ready…',
        _Phase.error => 'Could not start: $_error',
        _Phase.running when beat < score.fromBeat => 'Get ready',
        _Phase.running => 'Bar ${((beat - 1) ~/ 4 + 1).clamp(1, preset.bars)} of ${preset.bars}',
      },
      beatInBar: _phase == _Phase.running && beat >= 1 ? ((beat - 1).floor() % 4) : null,
    );
    final tally = _scoring ? _Tally(score) : const _CaptureNote();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmEnd();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(preset.name),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text('${preset.bpm.round()} bpm · ${widget.kind.title}',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth > c.maxHeight * 1.2) {
              // Landscape tablet: chart takes the full height, status and tally at the side.
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 8, 16), child: chart(wide: true))),
                  SizedBox(
                    width: (c.maxWidth * 0.3).clamp(280.0, 420.0),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          status,
                          const SizedBox(height: 16),
                          Expanded(child: tally),
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
                Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: chart(wide: false))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: SizedBox(height: 88, child: tally),
                ),
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: endButton),
              ],
            );
          },
        ),
      ),
    );
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
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          for (var i = 0; i < 4; i++)
            Container(
              width: 16,
              height: 16,
              margin: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: beatInBar == i ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
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
      child: ColoredBox(
        color: scheme.surface.withValues(alpha: 0.75),
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

/// What went wrong, large, over the chart while the practice rewind waits.
class _PracticeBanner extends StatelessWidget {
  const _PracticeBanner({required this.title, required this.detail});
  final String title, detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = theme.colorScheme.onInverseSurface;
    return LayoutBuilder(builder: (context, c) {
      // Sized from the chart so it reads from across the room on a tablet.
      final size = (c.maxWidth * 0.055).clamp(22.0, 48.0);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            elevation: 6,
            color: theme.colorScheme.inverseSurface,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: size, vertical: size * 0.9),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: size, color: on, fontWeight: FontWeight.w700, height: 1.2)),
                  SizedBox(height: size * 0.3),
                  Text(detail, textAlign: TextAlign.center, style: TextStyle(fontSize: size * 0.7, color: on)),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// Live counts, one per verdict, latest attempt per step. Zero stays neutral.
class _Tally extends StatelessWidget {
  const _Tally(this.score);
  final SessionScore score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tiles = [
      for (final v in const [Verdict.correct, Verdict.wrongStep, Verdict.offBeat, Verdict.missed])
        Expanded(child: _tile(theme, v, score.count(v))),
    ];
    return LayoutBuilder(
      builder: (context, c) => c.maxHeight > c.maxWidth
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: tiles)
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: tiles),
    );
  }

  Widget _tile(ThemeData theme, Verdict v, int n) {
    final color = n == 0 ? theme.colorScheme.onSurfaceVariant : v.color;
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: n == 0 ? theme.colorScheme.surfaceContainer : v.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      // Tight constraints, so the FittedBox scales the numbers up to fill the tile.
      child: FittedBox(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$n',
                  style:
                      theme.textTheme.displaySmall?.copyWith(color: color, fontWeight: FontWeight.w700, height: 1.1)),
              Text(v.label, style: theme.textTheme.titleMedium?.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CaptureNote extends StatelessWidget {
  const _CaptureNote();

  @override
  Widget build(BuildContext context) => Center(
        child: Text('Recording each node for training.',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
      );
}
