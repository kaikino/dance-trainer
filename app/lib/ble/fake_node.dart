import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'node_client.dart';
import 'protocol.dart';

/// A simulated ankle node for testing the app with no hardware.
///
/// It keeps its own microsecond clock, answers time sync, accepts a schedule,
/// and on Start plays the role of a dancer who is mostly right: each scheduled
/// step produces a step event near its beat, with a configurable share of
/// late, wrong, and missed steps. It also streams synthetic IMU batches at the
/// protocol's rate so the session recorder has something to write.
class FakeNodeClient extends NodeClient {
  FakeNodeClient(super.role, {int? seed}) : _rng = Random(seed ?? role.index + 475);

  final Random _rng;
  final _boot = DateTime.now().microsecondsSinceEpoch - 5000000;
  bool _connected = false;
  bool calibrated = false;
  Mode _mode = Mode.idle;
  double _bpm = 100;
  List<(double, StepClass)> _steps = [];
  final _timers = <Timer>[];
  Timer? _streamTimer;
  int _seq = 0;

  /// Error rates for the simulated dancer.
  double pLate = 0.10, pWrong = 0.10, pMissed = 0.06;

  int get _nodeNowUs => (DateTime.now().microsecondsSinceEpoch - _boot) & 0xffffffff;

  @override
  bool get connected => _connected;

  Future<void> connect() async {
    await Future<void>.delayed(Duration(milliseconds: 300 + _rng.nextInt(500)));
    _connected = true;
    _publishStatus();
    _startStream();
  }

  void _publishStatus() {
    status = Status(protocolVersion, role, 0x0002, role == Role.left ? 84 : 61, _mode);
    notifyListeners();
  }

  @override
  Future<int> syncTime({int rounds = 8}) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    offsetUs = _nodeNowUs - DateTime.now().microsecondsSinceEpoch;
    return offsetUs!;
  }

  @override
  Future<void> pushSchedule(int presetId, double bpm, List<(double, StepClass)> steps) async {
    _bpm = bpm;
    _steps = List.of(steps);
    debugPrint('fake $roleLabel: schedule preset=$presetId bpm=$bpm steps=${steps.length}');
  }

  @override
  Future<void> start(Mode mode, int t0AppMs) async {
    _cancelTimers();
    _mode = mode;
    _seq = 0;
    _publishStatus();
    final beatUs = 60e6 / _bpm;
    final t0NodeUs = appMsToNodeUs(t0AppMs);
    final nowNode = _nodeNowUs;
    for (final (beat, cls) in _steps) {
      final dueNodeUs = t0NodeUs + ((beat - 1) * beatUs).round();
      final fire = dueNodeUs - nowNode;
      if (fire < 0) continue;
      _timers.add(Timer(Duration(microseconds: fire), () => _step(dueNodeUs, cls)));
    }
    debugPrint('fake $roleLabel: start mode=${mode.name} t0=$t0NodeUs, ${_timers.length} steps queued');
  }

  void _step(int dueNodeUs, StepClass expected) {
    if (_mode == Mode.idle) return;
    final r = _rng.nextDouble();
    StepClass actual = expected;
    Verdict verdict = Verdict.correct;
    int errMs = (_rng.nextDouble() * 80 - 40).round();
    if (r < pMissed) {
      actual = StepClass.none;
      verdict = Verdict.missed;
      errMs = 0;
    } else if (r < pMissed + pWrong) {
      final others = StepClass.values.where((c) => c != expected && c != StepClass.none).toList();
      actual = others[_rng.nextInt(others.length)];
      verdict = Verdict.wrongStep;
    } else if (r < pMissed + pWrong + pLate) {
      errMs = 170 + _rng.nextInt(120);
      verdict = Verdict.offBeat;
    }
    if (_mode == Mode.capture) verdict = Verdict.unjudged;
    final strike = dueNodeUs + errMs * 1000;
    // Real nodes report ~200 ms after the strike (window tail + inference).
    final delay = verdict == Verdict.missed ? 300 : 200 + errMs;
    _timers.add(Timer(Duration(milliseconds: max(0, delay)), () {
      if (_mode == Mode.idle) return;
      emitEvent(StepEvent(_seq++, strike & 0xffffffff, actual, 180 + _rng.nextInt(75), expected, errMs, verdict));
    }));
  }

  @override
  Future<void> stop() async {
    _cancelTimers();
    _mode = Mode.idle;
    _publishStatus();
  }

  @override
  Future<void> calibrate() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    calibrated = true;
    debugPrint('fake $roleLabel: calibrated');
  }

  @override
  Future<void> buzzTest(Haptic h) async => debugPrint('fake $roleLabel: buzz ${h.name}');
  @override
  Future<void> setThreshold(int conf) async {}
  @override
  Future<void> setWindow(int ms) async {}

  @override
  Future<void> disconnect() async {
    _cancelTimers();
    _streamTimer?.cancel();
    _connected = false;
    notifyListeners();
  }

  void _cancelTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  // ---- synthetic IMU stream ---------------------------------------------------

  void _startStream() {
    _streamTimer?.cancel();
    _streamTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final capture = _mode == Mode.capture;
      final stepUs = capture ? 10000 : 20000;
      final t0 = _nodeNowUs - 100000;
      final acc = <StreamSample>[];
      final gyr = <StreamSample>[];
      for (var i = 0; i < StreamBatch.samplesPerBatch; i++) {
        int n() => (_rng.nextDouble() * 40 - 20).round();
        acc.add(StreamSample(1, 0, 0, 0, n(), n(), capture ? 1000 + n() : n(), false));
        if (capture) gyr.add(StreamSample(0x7fff / 16384.0, 0, 0, 0, n(), n(), n(), true));
      }
      emitBatch(StreamBatch(t0, acc));
      if (capture) {
        emitBatch(StreamBatch(t0, gyr));
        // 100 Hz = two accel batches per 100 ms.
        emitBatch(StreamBatch(t0 + 5 * stepUs, acc));
        emitBatch(StreamBatch(t0 + 5 * stepUs, gyr));
      }
    });
  }
}
