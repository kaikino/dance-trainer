import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../audio/beat_clock.dart';
import '../../ble/node_client.dart';
import '../../ble/protocol.dart';
import '../../chart/step_chart.dart';
import '../../models/preset.dart';
import '../../models/session_kind.dart';
import '../../models/session_score.dart';
import '../../store/history.dart';
import '../../store/session_store.dart';
import '../../ui/style.dart';

part 'holds.dart';

enum SessionPhase { preparing, running, error }

/// One dance session, without any widgets: the music, the nodes, the score,
/// the chart's state, and Practice's holds and rewinds. The dance screen
/// draws it and drives [tick] once a frame.
///
/// Sequence in [begin]: sync clocks → push schedule → start music → send
/// Start(t0) to the nodes. In [demo] ("Watch first") none of the nodes is
/// touched and nothing is recorded: the chart scrolls with the music and
/// calls out each step.
///
/// Every await is followed by a check that the session has not ended or been
/// paused meanwhile: End, a pause or a call may come at any point.
class DanceSession extends ChangeNotifier {
  DanceSession({
    required this.manager,
    required Preset preset,
    required this.kind,
    required this.dancer,
    this.fromBeat = 1,
    this.demo = false,
  })  : _preset = preset,
        score = SessionScore(preset),
        chart = StepChartController(preset),
        recorder = SessionRecorder(preset: preset, dancer: dancer, mode: kind.nodeMode, nodes: manager) {
    _clock = _newClock(preset);
    manager.addListener(_onNodes);
  }

  /// How long a practice mistake stays on screen before the rewind.
  static Duration practicePauseTime = const Duration(milliseconds: 2500);

  /// Practice "Slow down" plays at this share of the current tempo, down to
  /// [minTempo] of the routine's own.
  static const slowDownFactor = 0.8, minTempo = 0.5;

  final NodeManager manager;
  final SessionKind kind;
  final String dancer;

  /// Start here instead of beat 1 (a bar start), e.g. to drill one bar.
  final double fromBeat;

  /// Watch first: music and chart only.
  final bool demo;

  final SessionRecorder recorder;
  final SessionScore score;
  final StepChartController chart;
  final _coach = PracticeCoach();

  Preset _preset;
  late BeatClock _clock;

  /// The routine at the current tempo (Practice may slow it down).
  Preset get preset => _preset;
  BeatClock get clock => _clock;

  SessionPhase phase = SessionPhase.preparing;
  String? error;
  Hold? hold;
  bool ending = false;

  /// Practice "Keep going" moved past a bar: the run is not a complete one.
  bool _skippedBar = false;

  /// Called once the session has ended; [recorded] says whether there is a
  /// recording to summarise (never in [demo], or when it ended before starting).
  void Function(bool recorded)? onEnded;

  final _subs = <StreamSubscription<dynamic>>[];
  Future<void>? _recorderBegin;
  int? _t0AppMs; // beat 1 of the current segment
  bool _disposed = false;

  /// Nodes dancing in this session, and those that dropped out and are not
  /// back yet (the banner, for as long as any is missing).
  final _linked = <Role>{};
  final missing = <Role>{};
  bool reconnecting = false;

  /// Short-lived news about a node ("Left ankle reconnected").
  ({String text, bool ok})? toast;
  Timer? _toastTimer;

  /// Watch first: the steps just called out, and where in [Preset.beatOrder]
  /// the next call is.
  List<PresetStep> callout = const [];
  int _cueCursor = 0;

  /// Connected nodes with a synced clock.
  List<NodeClient> get live => manager.nodes.where((n) => n.connected && n.offsetUs != null).toList();
  bool get scoring => !demo && kind != SessionKind.capture;
  bool get practice => !demo && kind == SessionKind.practice;
  double get slowerFactor => max(minTempo / _preset.tempo, slowDownFactor);
  bool get canSlowDown => _preset.tempo > minTempo + 0.01;

  /// Whether the screen needs frames: not once the music is held, unless
  /// the chart is still fading out a hit.
  bool get needsFrames => !ending && phase != SessionPhase.error && (hold == null || chart.animating);

  /// The steps at the next beat to be called out (watch first).
  List<PresetStep> get upcoming {
    final order = _preset.beatOrder;
    final steps = _preset.steps;
    for (var k = _cueCursor; k < order.length; k++) {
      final s = steps[order[k]];
      if (s.stepClass == StepClass.none) continue;
      return [
        for (var j = k; j < order.length && steps[order[j]].beat == s.beat; j++)
          if (steps[order[j]].stepClass != StepClass.none) steps[order[j]],
      ];
    }
    return const [];
  }

  BeatClock _newClock(Preset p) =>
      BeatClock(p)..onInterrupted = () => pause('The music was interrupted by another app or a call.');

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> begin() async {
    final run = _run = Object();
    try {
      await _clock.prepare();
      if (_stale(run)) return;
      final from = fromBeat;
      if (!demo) {
        await (_recorderBegin = recorder.begin());
        if (_stale(run)) return;
        for (final n in manager.nodes) {
          // Every node: one that comes back mid-session keeps the same stream.
          _subs.add(n.events.listen((e) => _onEvent(n, e)));
        }
        final nodes = manager.connectedNodes;
        if (nodes.isEmpty) throw const BleUnavailable('No ankle node is connected. Go back and scan for them.');
        for (final n in nodes) {
          // Always: a node may have rebooted or drifted since the last session.
          await n.syncTime();
          recorder.noteNode(n);
          if (_stale(run)) return;
          await n.pushSchedule(_preset.id, _preset.bpm, _preset.scheduleFor(n.role, fromBeat: from));
          if (_stale(run)) return;
          _linked.add(n.role);
        }
      }
      if (from > 1) score.restart(fromBeat: from);
      _seekCues(from);
      // Sent to the background while getting ready: wait, paused, for the
      // dancer instead of starting unseen.
      if (_pendingPause case final reason?) {
        _run = null;
        phase = SessionPhase.running;
        hold = PausedHold(reason, from);
        _changed();
        return;
      }
      final t0 = from > 1 ? await _clock.resumeFrom(from) : await _clock.start();
      if (_stale(run)) return await _afterStale();
      _t0AppMs = t0;
      if (!demo) recorder.addSegment(t0, fromBeat: from, bpm: _preset.bpm);
      phase = SessionPhase.running;
      _changed();
      if (_pendingPause case final reason?) return pause(reason);
      if (demo) return _done(run);
      for (final n in live) {
        await n.start(kind.nodeMode, t0);
        if (_stale(run)) return await _afterStale();
      }
      _done(run);
    } catch (e) {
      if (_disposed || ending) return;
      _run = null;
      phase = SessionPhase.error;
      error = '$e';
      _changed();
    }
  }

  /// The [begin] or [resumeFrom] in flight. A pause or End makes it stale:
  /// it stops at its next await instead of playing on under the hold.
  Object? _run;

  /// A pause asked for while getting ready, applied once [begin] gets there.
  String? _pendingPause;

  bool _stale(Object run) => ending || _disposed || _run != run;
  void _done(Object run) {
    if (_run == run) _run = null;
  }

  /// A start that went stale may have started the music or a node after the
  /// pause stopped them: stop them again, unless a newer start is under way.
  Future<void> _afterStale() async {
    if (_disposed || ending || _run != null) return;
    await _haltPlayback();
  }

  /// Advances the chart to the clock; call once a frame. Ends the session
  /// when the music is over. Returns the current beat.
  double tick() {
    final beat = _clock.nowBeat;
    chart.tick(beat);
    if (demo && phase == SessionPhase.running && hold == null) _cue(beat);
    if (phase == SessionPhase.running && hold == null && _clock.finished && !ending) {
      unawaited(end(complete: true));
    }
    return beat;
  }

  // ---- watch first -------------------------------------------------------------

  void _seekCues(double beat) {
    final order = _preset.beatOrder;
    _cueCursor = 0;
    while (_cueCursor < order.length && _preset.steps[order[_cueCursor]].beat < beat) {
      _cueCursor++;
    }
  }

  void _cue(double beat) {
    final order = _preset.beatOrder;
    final steps = _preset.steps;
    final called = <PresetStep>[];
    while (_cueCursor < order.length && steps[order[_cueCursor]].beat <= beat) {
      final s = steps[order[_cueCursor++]];
      if (s.stepClass == StepClass.none) continue;
      if (called.isNotEmpty && called.last.beat != s.beat) called.clear();
      called.add(s);
    }
    if (called.isEmpty) return;
    for (final s in called) {
      chart.cue(s.foot, stepLabel(s.stepClass));
    }
    callout = called;
    _changed();
  }

  // ---- step events -------------------------------------------------------------

  void _onEvent(NodeClient n, StepEvent e) {
    final t0 = _t0AppMs;
    if (_disposed || ending || !scoring || hold != null || t0 == null || n.offsetUs == null) return;
    final r = score.addStrike(n.role, e, strikeMs: n.msAfter(e.tStrikeNodeUs, t0), beatMs: _preset.beatMs);
    if (r.fate == EventFate.duplicate) return;
    final i = r.step;
    if (i != null) chart.hit(n.role, e.verdict, timingErrMs: e.timingErrMs);
    chart.setVerdicts(score.shown);
    _changed(); // the tally
    if (!practice || i == null) return;
    final step = score.preset.steps[i];
    switch (_coach.onMistake(e.verdict, step.beat)) {
      case PracticeAction.carryOn:
        break;
      case PracticeAction.rewind:
        unawaited(_practiceRewind(n.role, e, step));
      case PracticeAction.offerChoice:
        _run = null;
        hold = ChoiceHold(Preset.barStart(step.beat));
        _changed();
        unawaited(_haltPlayback());
    }
  }

  // ---- holds and restarts ------------------------------------------------------

  /// Stops the music and the nodes; the chart holds where it is.
  Future<void> _haltPlayback() async {
    await _clock.pause();
    if (!demo) await _stopNodes(live);
  }

  static Future<void> _stopNodes(List<NodeClient> nodes) async {
    for (final n in nodes) {
      try {
        await n.stop();
      } catch (_) {}
    }
  }

  Future<void> _practiceRewind(Role foot, StepEvent e, PresetStep step) async {
    final barStart = Preset.barStart(step.beat);
    final name = footName(foot);
    final (title, detail) = switch (e.verdict) {
      Verdict.wrongStep => (
          'Wrong step',
          '$name foot: ${stepLabel(e.stepClass)} instead of ${stepLabel(step.stepClass)}'
        ),
      _ => ('Missed step', '$name foot: ${stepLabel(step.stepClass)}'),
    };
    final h = MistakeHold(e.verdict, title, detail, barStart, _coach.nextTry);
    _run = null;
    hold = h;
    _changed();
    await _haltPlayback();
    await Future<void>.delayed(practicePauseTime);
    // Ended, or paused meanwhile (then Resume takes over).
    if (_disposed || ending || hold != h) return;
    score.rewind(barStart);
    await resumeFrom(barStart);
  }

  /// Back to [beat] (a bar start) with a count-in. The nodes get only the
  /// steps from there on, so the replayed count-in is not judged. On failure
  /// the overlay offers Try again and End instead of hanging. A pause while
  /// this is under way wins: the session stays held.
  Future<void> resumeFrom(double beat) async {
    if (ending || _disposed) return;
    final run = _run = Object();
    score.restart(fromBeat: beat);
    chart.setVerdicts(score.shown);
    _seekCues(beat);
    try {
      final nodes = demo ? const <NodeClient>[] : live;
      for (final n in nodes) {
        await n.pushSchedule(_preset.id, _preset.bpm, _preset.scheduleFor(n.role, fromBeat: beat));
        if (_stale(run)) return await _afterStale();
      }
      final t0 = await _clock.resumeFrom(beat);
      if (_stale(run)) return await _afterStale();
      _t0AppMs = t0;
      if (!demo) recorder.addSegment(t0, fromBeat: beat, bpm: _preset.bpm);
      hold = null;
      _changed();
      for (final n in nodes) {
        await n.start(kind.nodeMode, t0);
        if (_stale(run)) return await _afterStale();
      }
      _done(run);
    } catch (e) {
      if (_stale(run)) return await _afterStale();
      _run = null;
      await _haltPlayback();
      if (ending || _disposed) return;
      hold = FailedHold('Could not restart: $e', beat);
      _changed();
    }
  }

  /// Pauses the session (app backgrounded, music interrupted). While getting
  /// ready, the pause waits for [begin] to get there. A start under way
  /// (Resume, Try again, Keep going just pressed) is called off.
  void pause(String reason) {
    if (ending || _disposed) return;
    if (phase == SessionPhase.preparing) {
      _pendingPause ??= reason;
      return;
    }
    if (phase != SessionPhase.running) return;
    final h = hold;
    final starting = _run != null;
    // Already stopped, with its own buttons.
    if (!starting && (h is PausedHold || h is ChoiceHold || h is FailedHold)) return;
    _run = null;
    _pendingPause = null;
    final from = h?.fromBeat ?? max(score.fromBeat, Preset.barStart(max(1.0, _clock.nowBeat)));
    hold = PausedHold(reason, from);
    _changed();
    unawaited(_haltPlayback());
  }

  Future<void> slowDown(double fromBeat) async {
    if (ending || _disposed) return;
    final run = _run = Object();
    _coach.slowDown();
    final slower = _preset.withTempo(slowerFactor);
    final clock = _newClock(slower);
    try {
      await clock.prepare();
    } catch (e) {
      clock.dispose();
      if (_stale(run)) return;
      _run = null;
      hold = FailedHold('Could not change the tempo: $e', fromBeat);
      _changed();
      return;
    }
    if (_stale(run)) {
      clock.dispose();
      return;
    }
    final old = _clock;
    _clock = clock;
    _preset = slower;
    chart.preset = slower;
    _changed();
    old.dispose();
    score.rewind(fromBeat);
    await resumeFrom(fromBeat);
  }

  Future<void> keepGoing(double barStart) async {
    _coach.keepGoing();
    _skippedBar = true;
    final next = barStart + 4;
    if (next > _preset.lastBeat) return end(complete: true);
    await resumeFrom(next);
  }

  // ---- nodes dropping out ------------------------------------------------------

  void _onNodes() {
    if (_disposed || demo || ending || phase != SessionPhase.running) return;
    for (final n in manager.nodes) {
      if (_linked.contains(n.role) && !n.connected) {
        _linked.remove(n.role);
        missing.add(n.role);
        _changed();
      } else if (!_linked.contains(n.role) && n.connected && n.status != null) {
        _linked.add(n.role);
        unawaited(_rejoin(n));
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
      if (hold == null && t0 != null && !ending) {
        final from = max(score.fromBeat, Preset.barStart(max(1.0, _clock.nowBeat)) + 4);
        await n.pushSchedule(_preset.id, _preset.bpm, _preset.scheduleFor(n.role, fromBeat: from));
        await n.start(kind.nodeMode, t0);
      }
      missing.remove(n.role);
      _changed();
      _showToast('$foot ankle reconnected', ok: true);
    } catch (e) {
      _linked.remove(n.role);
      missing.add(n.role);
      _changed();
      _showToast('$foot ankle could not rejoin', ok: false);
    }
  }

  /// The banner's Reconnect: scan for the missing nodes now instead of
  /// waiting for the automatic retries.
  Future<void> reconnectNodes() async {
    reconnecting = true;
    _changed();
    try {
      await manager.scanAndConnect();
    } on BleUnavailable catch (e) {
      _showToast(e.message, ok: false);
    } catch (e) {
      _showToast('Could not reconnect: $e', ok: false);
    } finally {
      reconnecting = false;
      _changed();
    }
  }

  void _showToast(String text, {required bool ok}) {
    if (_disposed) return;
    _toastTimer?.cancel();
    toast = (text: text, ok: ok);
    _changed();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      toast = null;
      _changed();
    });
  }

  // ---- ending ------------------------------------------------------------------

  /// Stops everything and saves. [complete]: the routine was danced to its end
  /// (an End press, an error or a drill from a later bar is not).
  Future<void> end({bool complete = false}) async {
    if (ending) return;
    ending = true;
    _changed();
    await _clock.stop();
    if (!demo) await _stopNodes(manager.connectedNodes);
    final recorded =
        await _finishRecording(complete: complete && fromBeat <= 1 && phase == SessionPhase.running && !_skippedBar);
    if (_disposed) return;
    onEnded?.call(recorded);
  }

  /// Waits for the recorder to have begun (if it was started) and ends it.
  Future<bool> _finishRecording({required bool complete}) async {
    final b = _recorderBegin;
    if (b == null) return false;
    try {
      await b;
    } catch (_) {
      return false;
    }
    if (recorder.segments.isEmpty) {
      // Ended before the music started: nothing was danced, nothing to keep.
      await recorder.discard();
      return false;
    }
    await recorder.end(
      score: scoring
          ? HistoryEntry.summarize(score,
              kind: kind, complete: complete, bpms: [for (final g in recorder.segments) g.bpm])
          : null,
    );
    return true;
  }

  @override
  void dispose() {
    manager.removeListener(_onNodes);
    _toastTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    if (!ending) {
      // Left without End (e.g. the route was removed): never leave the nodes
      // dancing or the recording open.
      ending = true;
      if (!demo) unawaited(_stopNodes(manager.connectedNodes));
      unawaited(_finishRecording(complete: false));
    }
    _disposed = true;
    _clock.dispose();
    chart.dispose();
    super.dispose();
  }
}
