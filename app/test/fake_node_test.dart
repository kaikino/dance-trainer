import 'package:dance_trainer/ble/clock_sync.dart';
import 'package:dance_trainer/ble/fake_node.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The simulated node behaves like firmware where the recorder depends on it.
void main() {
  const steps = [(1.0, StepClass.forward), (2.0, StepClass.back), (3.0, StepClass.forward)];

  Future<(FakeNodeClient, List<StepEvent>)> dance(Mode mode, {double pMissed = 0}) async {
    final n = FakeNodeClient(Role.left, seed: 1)
      ..pMissed = pMissed
      ..pWrong = 0
      ..pLate = 0;
    await n.connect();
    await n.syncTime();
    final events = <StepEvent>[];
    n.events.listen(events.add);
    await n.pushSchedule(1, 240, steps);
    await n.start(mode, DateTime.now().millisecondsSinceEpoch + 100);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await n.disconnect();
    return (n, events);
  }

  test('capture mode does not judge: no expected class, timing or verdict', () async {
    final (_, events) = await dance(Mode.capture);
    expect(events, hasLength(steps.length));
    for (final e in events) {
      expect(e.expectedClass, StepClass.none);
      expect(e.timingErrMs, 0);
      expect(e.verdict, Verdict.unjudged);
      expect(e.stepClass, isNot(StepClass.none));
    }
  });

  test('a step not felt in capture sends nothing; in dance it is reported missed', () async {
    expect((await dance(Mode.capture, pMissed: 1)).$2, isEmpty);
    final (_, missed) = await dance(Mode.dance, pMissed: 1);
    expect(missed, hasLength(steps.length));
    expect(missed.map((e) => e.verdict).toSet(), {Verdict.missed});
  });

  test('stream batches: monotonic times at the firmware rates, gyro twin in capture', () async {
    final n = FakeNodeClient(Role.right, seed: 2);
    final batches = <StreamBatch>[];
    n.batches.listen(batches.add);
    await n.connect();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final idle = List.of(batches);
    await n.syncTime();
    await n.start(Mode.capture, DateTime.now().millisecondsSinceEpoch);
    batches.clear();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await n.disconnect();

    void expectSpacing(List<StreamBatch> bs, Mode mode) {
      final perBatch = StreamBatch.samplesPerBatch * StreamBatch.sampleUs(mode);
      for (var i = 1; i < bs.length; i++) {
        expect(u32DeltaUs(bs[i].t0NodeUs, bs[i - 1].t0NodeUs), closeTo(perBatch, 2));
      }
    }

    expect(idle.length, greaterThanOrEqualTo(3));
    expect(idle.any((b) => b.samples.first.isGyro), isFalse);
    expectSpacing(idle, Mode.idle);

    final acc = [for (final b in batches) if (!b.samples.first.isGyro) b];
    final gyr = [for (final b in batches) if (b.samples.first.isGyro) b];
    expect(acc.length, greaterThanOrEqualTo(6));
    expect([for (final b in gyr) b.t0NodeUs], [for (final b in acc) b.t0NodeUs]);
    expectSpacing(acc, Mode.capture);
    expect(u32DeltaUs(acc.first.t0NodeUs, idle.last.t0NodeUs), greaterThan(0));
  });
}
