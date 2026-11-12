import 'dart:async';

import 'package:dance_trainer/ble/clock_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('u32 node clock', () {
    test('signed difference across the wrap', () {
      expect(u32DeltaUs(5, 0xfffffffb), 10);
      expect(u32DeltaUs(0xfffffffb, 5), -10);
      expect(u32DeltaUs(1000, 400), 600);
    });

    test('a strike after the node clock wrapped lands at the right app time', () {
      // Synced when the node clock read 0xFFF00000 µs at app time 1 000 000 ms.
      const appMs = 1000000;
      const nodeAtSync = 0xFFF00000;
      const offset = nodeAtSync - appMs * 1000;
      // t0 is 0.5 s later; the strike is 2 s after that, past the wrap.
      const t0 = appMs + 500;
      const strike = (nodeAtSync + 2500000) & 0xffffffff;
      expect(strike, lessThan(nodeAtSync)); // it did wrap
      expect(nodeMsAfter(strike, t0, offset), 2000.0);
      // The naive subtraction is off by 71.6 minutes.
      expect(((strike - offset) / 1000 - t0).abs(), greaterThan(4e6));
    });

    test('a strike just before t0 is negative', () {
      const offset = -123456789;
      const t0Node = (5000 * 1000 + offset) & 0xffffffff;
      expect(nodeMsAfter((t0Node - 20000) & 0xffffffff, 5000, offset), -20.0);
    });
  });

  group('time sync', () {
    SyncSample sample(int sent, int rtt, int offsetUs) =>
        (sentMs: sent, nodeUs: (sent * 1000 + rtt * 500 + offsetUs), receivedMs: sent + rtt);

    test('keeps the round with the shortest round trip', () async {
      final rtts = [30, 12, 50];
      var i = 0;
      final off = await estimateOffset(() async {
        final rtt = rtts[i++];
        // The node read its clock at the midpoint; long rounds carry 1 ms of skew.
        return sample(1000 + i * 100, rtt, 777000 + (rtt == 12 ? 0 : 1000));
      }, rounds: 3);
      expect(off, 777000);
    });

    test('a lost round is skipped, not fatal', () async {
      var i = 0;
      final off = await estimateOffset(() async {
        i++;
        if (i.isOdd) throw TimeoutException('lost');
        return sample(1000 * i, 10, 42000);
      }, rounds: 4);
      expect(i, 4);
      expect(off, 42000);
    });

    test('fails only when every round is lost', () async {
      await expectLater(
        estimateOffset(() async => throw TimeoutException('lost'), rounds: 3),
        throwsA(isA<TimeSyncFailed>()),
      );
    });

    test('other errors (disconnected) are not swallowed', () async {
      await expectLater(estimateOffset(() async => throw StateError('gone'), rounds: 3), throwsStateError);
    });
  });
}
