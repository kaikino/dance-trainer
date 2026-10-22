import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'protocol.dart';

/// One ankle node. Wraps the GATT characteristics from docs/ble-protocol.md.
class NodeClient extends ChangeNotifier {
  NodeClient(this.role);

  final Role role;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _status, _timeSync, _schedule, _control, _stepEvent, _stream;

  Status? status;
  bool get connected => _device?.isConnected ?? false;
  String get name => role == Role.left ? 'DT-L' : 'DT-R';
  String get roleLabel => role == Role.left ? 'L' : 'R';

  /// t_app_us = t_node_us − offsetUs. Set by [syncTime].
  int? offsetUs;

  final _events = StreamController<StepEvent>.broadcast();
  final _batches = StreamController<StreamBatch>.broadcast();
  Stream<StepEvent> get events => _events.stream;
  Stream<StreamBatch> get batches => _batches.stream;

  Future<void> connect(BluetoothDevice device) async {
    _device = device;
    await device.connect(timeout: const Duration(seconds: 10));
    await device.requestMtu(247);
    await device.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);

    final services = await device.discoverServices();
    final svc = services.firstWhere((s) => s.uuid.str128 == uuidService);
    for (final c in svc.characteristics) {
      final u = c.uuid.str128;
      if (u == uuidStatus) _status = c;
      if (u == uuidTimeSync) _timeSync = c;
      if (u == uuidSchedule) _schedule = c;
      if (u == uuidControl) _control = c;
      if (u == uuidStepEvent) _stepEvent = c;
      if (u == uuidStream) _stream = c;
    }

    status = Status.parse(await _status!.read());
    await _status!.setNotifyValue(true);
    _status!.onValueReceived.listen((b) {
      status = Status.parse(b);
      notifyListeners();
    });
    await _stepEvent!.setNotifyValue(true);
    _stepEvent!.onValueReceived.listen((b) => _events.add(StepEvent.parse(b)));
    await _stream!.setNotifyValue(true);
    _stream!.onValueReceived.listen((b) => _batches.add(StreamBatch.parse(b)));
    await _timeSync!.setNotifyValue(true);

    device.connectionState.listen((_) => notifyListeners());
    notifyListeners();
  }

  /// 8 round trips, keep the one with the smallest RTT.
  Future<int> syncTime({int rounds = 8}) async {
    int? best, bestRtt;
    for (var i = 0; i < rounds; i++) {
      final reply = _timeSync!.onValueReceived.first;
      final t0 = DateTime.now().millisecondsSinceEpoch;
      await _timeSync!.write(encodeTimeSyncRequest(t0), withoutResponse: true);
      final r = TimeSyncReply.parse(await reply.timeout(const Duration(seconds: 1)));
      final t1 = DateTime.now().millisecondsSinceEpoch;
      final rtt = t1 - t0;
      if (bestRtt == null || rtt < bestRtt) {
        bestRtt = rtt;
        best = r.tNodeUs - (t0 + rtt ~/ 2) * 1000;
      }
    }
    offsetUs = best;
    return best!;
  }

  int appMsToNodeUs(int tAppMs) => tAppMs * 1000 + offsetUs!;

  Future<void> pushSchedule(int presetId, double bpm, List<(double, StepClass)> steps) async {
    for (final chunk in encodeSchedule(presetId, bpm, steps)) {
      await _schedule!.write(chunk);
    }
  }

  Future<void> start(Mode mode, int t0AppMs) =>
      _control!.write(encodeStart(mode, appMsToNodeUs(t0AppMs)));
  Future<void> stop() => _control!.write(encodeCmd(Cmd.stop));
  Future<void> calibrate() => _control!.write(encodeCmd(Cmd.calibrate));
  Future<void> buzzTest(Haptic h) => _control!.write(encodeCmd(Cmd.buzzTest, [h.index]));
  Future<void> setThreshold(int conf) => _control!.write(encodeCmd(Cmd.setThreshold, [conf]));
  Future<void> setWindow(int ms) => _control!.write(encodeSetWindow(ms));

  Future<void> disconnect() => _device?.disconnect() ?? Future.value();
}

/// Both nodes. Scans for DT-L and DT-R and connects each.
class NodeManager extends ChangeNotifier {
  final left = NodeClient(Role.left);
  final right = NodeClient(Role.right);
  List<NodeClient> get nodes => [left, right];

  NodeManager() {
    for (final n in nodes) {
      n.addListener(notifyListeners);
    }
  }

  Future<void> scanAndConnect() async {
    await FlutterBluePlus.startScan(
      withNames: ['DT-L', 'DT-R'],
      timeout: const Duration(seconds: 8),
    );
    final seen = <String>{};
    await for (final results in FlutterBluePlus.scanResults) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        if (!seen.add(name)) continue;
        final node = name == 'DT-L' ? left : right;
        if (!node.connected) unawaited(node.connect(r.device));
      }
      if (seen.length == 2) break;
    }
    await FlutterBluePlus.stopScan();
  }

  Future<void> syncAll() => Future.wait(nodes.where((n) => n.connected).map((n) => n.syncTime()));
}
