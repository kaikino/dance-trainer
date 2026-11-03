import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/beat_clock.dart';
import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../chart/step_chart.dart';
import '../models/preset.dart';
import '../store/session_store.dart';
import 'preset_screen.dart';
import 'summary_screen.dart';

/// The live screen: music, scrolling step chart, verdicts from the nodes.
/// Sequence on entry: push schedule → start music → send Start(t0) to nodes.
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

class _DanceScreenState extends State<DanceScreen> {
  late final BeatClock clock;
  late final SessionRecorder recorder;
  final verdicts = <int, Verdict>{};
  final _subs = <StreamSubscription<dynamic>>[];
  var correct = 0, wrong = 0, late = 0, missed = 0;
  String phase = 'preparing';
  bool _paused = false;
  bool _ending = false;
  String? _practiceNote;

  Preset get preset => widget.preset;
  NodeManager get m => widget.manager;
  Iterable<NodeClient> get live => m.nodes.where((n) => n.connected);

  @override
  void initState() {
    super.initState();
    clock = BeatClock(preset);
    recorder = SessionRecorder(preset: preset, dancer: widget.dancer, mode: widget.kind.nodeMode, nodes: m);
    clock.addListener(_tick);
    _begin();
  }

  Future<void> _begin() async {
    try {
      await clock.prepare();
      await recorder.begin();
      for (final n in live) {
        if (n.offsetUs == null) await n.syncTime();
        await n.pushSchedule(preset.id, preset.bpm, preset.scheduleFor(n.role));
        _subs.add(n.events.listen((e) => _onEvent(n, e)));
      }
      setState(() => phase = 'count-in');
      final t0 = await clock.start();
      recorder.t0AppMs = t0;
      for (final n in live) {
        await n.start(widget.kind.nodeMode, t0);
      }
    } catch (e) {
      if (mounted) setState(() => phase = 'error: $e');
    }
  }

  void _tick() {
    if (!mounted) return;
    if (clock.finished && !_ending) {
      _end();
      return;
    }
    setState(() {
      if (phase == 'count-in' && clock.nowBeat >= 1) phase = 'dancing';
    });
  }

  /// Index into preset.steps of the scheduled step this event refers to.
  int? _stepIndex(NodeClient n, StepEvent e) {
    if (recorder.t0AppMs == null || n.offsetUs == null) return null;
    final tAppMs = (e.tStrikeNodeUs - n.offsetUs!) / 1000.0;
    final beatT = tAppMs - recorder.t0AppMs!;
    int? best;
    var bestErr = double.infinity;
    for (var i = 0; i < preset.steps.length; i++) {
      final s = preset.steps[i];
      if (s.foot != n.role) continue;
      final err = (preset.beatToMs(s.beat) - beatT).abs();
      if (err < bestErr) {
        bestErr = err;
        best = i;
      }
    }
    return bestErr <= preset.beatMs * 0.75 ? best : null;
  }

  void _onEvent(NodeClient n, StepEvent e) {
    if (!mounted || widget.kind == SessionKind.capture) return;
    final i = _stepIndex(n, e);
    setState(() {
      if (i != null) verdicts[i] = e.verdict;
      switch (e.verdict) {
        case Verdict.correct:
          correct++;
        case Verdict.wrongStep:
          wrong++;
        case Verdict.offBeat:
          late++;
        case Verdict.missed:
          missed++;
        default:
          break;
      }
    });
    final mistake = e.verdict == Verdict.wrongStep || e.verdict == Verdict.missed || e.verdict == Verdict.offBeat;
    if (widget.kind == SessionKind.practice && mistake && !_paused && i != null) {
      _practicePause(n, e, preset.steps[i]);
    }
  }

  Future<void> _practicePause(NodeClient n, StepEvent e, PresetStep step) async {
    _paused = true;
    final what = switch (e.verdict) {
      Verdict.wrongStep => '${e.stepClass.name} instead of ${step.stepClass.name}',
      Verdict.missed => 'missed',
      _ => '${e.timingErrMs > 0 ? 'late' : 'early'} by ${e.timingErrMs.abs()} ms',
    };
    setState(() => _practiceNote = '${n.roleLabel == 'L' ? 'Left' : 'Right'} foot: $what. Rewinding one bar.');
    await clock.pause();
    for (final c in live) {
      await c.stop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    // Back to the start of the bar this step is in, with a count-in.
    final barStart = ((step.beat - 1) ~/ 4) * 4 + 1.0;
    for (var i = 0; i < preset.steps.length; i++) {
      if (preset.steps[i].beat >= barStart) verdicts.remove(i);
    }
    final t0 = await clock.resumeFrom(barStart);
    recorder.t0AppMs = t0;
    for (final c in live) {
      await c.start(Mode.dance, t0);
    }
    setState(() {
      _practiceNote = null;
      _paused = false;
    });
  }

  Future<void> _end() async {
    if (_ending) return;
    _ending = true;
    await clock.stop();
    for (final n in live) {
      try {
        await n.stop();
      } catch (_) {}
    }
    await recorder.end();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SummaryScreen(preset: preset, recorder: recorder, kind: widget.kind),
      ),
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    clock.removeListener(_tick);
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final beat = clock.nowBeat;
    final bar = beat < 1 ? 0 : ((beat - 1) ~/ 4) + 1;
    final bars = ((preset.lastBeat - 1) ~/ 4) + 1;
    final countIn = beat < 1 ? (1 - beat).ceil() : 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(preset.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Text('${preset.bpm.round()} bpm · ${widget.kind.name}')),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(phase == 'dancing' ? 'bar $bar of $bars' : phase),
                if (countIn > 0) Text('$countIn', style: Theme.of(context).textTheme.headlineMedium),
              ],
            ),
          ),
          if (_practiceNote != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_practiceNote!, style: const TextStyle(fontSize: 16)),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: StepChart(preset: preset, nowBeat: beat, verdicts: verdicts),
            ),
          ),
          if (widget.kind != SessionKind.capture)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Text('correct $correct'),
                  Text('wrong $wrong', style: const TextStyle(color: Colors.red)),
                  Text('late $late'),
                  Text('missed $missed'),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Recording 100 Hz from each node for training.'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(onPressed: _end, child: const Text('End session')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
