import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'clock_sync.dart';
import 'fake_node.dart';
import 'protocol.dart';

/// One ankle node, as the rest of the app sees it. [BleNodeClient] talks to a
/// real node over GATT (docs/ble-protocol.md); [FakeNodeClient] simulates one
/// in-process for testing on an emulator or desktop with no hardware.
abstract class NodeClient extends ChangeNotifier {
  NodeClient(this.role);

  final Role role;
  Status? status;
  bool get connected;
  String get name => role == Role.left ? 'DT-L' : 'DT-R';
  String get roleLabel => role == Role.left ? 'L' : 'R';

  /// t_node_us − t_app_us, modulo 2^32 (see clock_sync.dart). Set by [syncTime].
  int? offsetUs;

  final _events = StreamController<StepEvent>.broadcast();
  final _batches = StreamController<StreamBatch>.broadcast();

  /// Step events and stream batches. The same streams across reconnects, so a
  /// listener does not need to resubscribe when the node comes back.
  Stream<StepEvent> get events => _events.stream;
  Stream<StreamBatch> get batches => _batches.stream;

  @protected
  void emitEvent(StepEvent e) => _events.add(e);
  @protected
  void emitBatch(StreamBatch b) => _batches.add(b);

  int appMsToNodeUs(int tAppMs) => tAppMs * 1000 + offsetUs!;

  /// Milliseconds after app time [refAppMs] at which node time [tNodeUs]
  /// happened. Safe across the node's u32 clock wrap.
  double msAfter(int tNodeUs, int refAppMs) => nodeMsAfter(tNodeUs, refAppMs, offsetUs!);

  Future<int> syncTime({int rounds = 8});
  Future<void> pushSchedule(int presetId, double bpm, List<(double, StepClass)> steps);
  Future<void> start(Mode mode, int t0AppMs);
  Future<void> stop();
  Future<void> calibrate();
  Future<void> cancelCalibration();
  Future<void> buzzTest(Haptic h);
  Future<void> setThreshold(int conf);
  Future<void> setWindow(int ms);
  Future<void> disconnect();
}

/// The device answered but is not the node we wanted (no Dance Trainer
/// service, or it reports the other foot).
class NotADanceNode implements Exception {
  const NotADanceNode(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Wait before reconnect attempt [attempt] (0-based) after a drop: 0.5 s,
/// doubling, at most [cap].
Duration reconnectDelay(int attempt, {Duration cap = const Duration(seconds: 5)}) {
  final ms = 500 * (1 << attempt.clamp(0, 16));
  return ms < cap.inMilliseconds ? Duration(milliseconds: ms) : cap;
}

/// A real node over Bluetooth LE.
class BleNodeClient extends NodeClient {
  BleNodeClient(super.role, {this.reconnectCap = const Duration(seconds: 5)});

  /// Longest wait between reconnect attempts after an unexpected drop.
  final Duration reconnectCap;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _timeSync, _schedule, _control;

  /// Every listener set up by [connect]; all cancelled before the next one, so
  /// a reconnect never delivers a notification twice.
  final _subs = <StreamSubscription<dynamic>>[];
  bool _ready = false;

  /// False once the app disconnects on purpose: no automatic reconnect then.
  bool _wanted = false;
  bool _reconnecting = false;
  Future<void>? _connecting;

  @override
  bool get connected => _ready && (_device?.isConnected ?? false);

  /// Connects and sets up notifications. On any failure the link is torn down
  /// and the error rethrown, so a half-set-up node never reports connected.
  /// Concurrent calls share one attempt.
  Future<void> connect(BluetoothDevice device) =>
      _connecting ??= _connect(device).whenComplete(() => _connecting = null);

  Future<void> _connect(BluetoothDevice device) async {
    await _resetLink();
    _device = device;
    _wanted = true;
    offsetUs = null; // a reconnected node may have rebooted: its clock must be synced again
    try {
      await device.connect(timeout: const Duration(seconds: 10));
      if (Platform.isAndroid) {
        // Android only (FBP throws elsewhere).
        await device.requestMtu(247);
        await device.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
      }

      final label = device.advName.isEmpty ? device.remoteId.str : device.advName;
      final services = await device.discoverServices();
      final svc = services.where((s) => s.uuid.str128 == uuidService).firstOrNull;
      if (svc == null) throw NotADanceNode('$label is not a Dance Trainer node.');
      BluetoothCharacteristic ch(String uuid) => svc.characteristics.firstWhere((c) => c.uuid.str128 == uuid,
          orElse: () => throw NotADanceNode('$label has old or different firmware.'));
      final statusCh = ch(uuidStatus), stepCh = ch(uuidStepEvent), streamCh = ch(uuidStream);
      _timeSync = ch(uuidTimeSync);
      _schedule = ch(uuidSchedule);
      _control = ch(uuidControl);

      final st = Status.parse(await statusCh.read());
      if (st.role != role) {
        throw NotADanceNode('$label says it is the ${st.role.name} node; expected $name.');
      }
      status = st;

      // Listen before enabling notifications so none is lost.
      _subs.add(statusCh.onValueReceived.listen((b) {
        status = Status.parse(b);
        notifyListeners();
      }));
      _subs.add(stepCh.onValueReceived.listen((b) => emitEvent(StepEvent.parse(b))));
      _subs.add(streamCh.onValueReceived.listen((b) => emitBatch(StreamBatch.parse(b))));
      for (final c in [statusCh, stepCh, streamCh, _timeSync!]) {
        await c.setNotifyValue(true);
      }
      _ready = true;
      _subs.add(device.connectionState.listen(_onConnectionState));
      notifyListeners();
    } catch (e) {
      debugPrint('$name: connect failed: $e');
      await _resetLink();
      try {
        await device.disconnect();
      } catch (_) {}
      notifyListeners();
      rethrow;
    }
  }

  void _onConnectionState(BluetoothConnectionState s) {
    notifyListeners();
    if (s == BluetoothConnectionState.disconnected && _wanted) unawaited(_reconnect());
  }

  /// After an unexpected drop, keep trying to get the node back, with
  /// backoff, until it is back or the app lets it go ([disconnect]). A dancer
  /// who walked out of range for a minute gets the node back on return.
  Future<void> _reconnect() async {
    final device = _device;
    if (device == null || _reconnecting) return;
    _reconnecting = true;
    try {
      for (var i = 0;; i++) {
        await Future<void>.delayed(reconnectDelay(i, cap: reconnectCap));
        if (!_wanted || connected || _device != device) return;
        try {
          // A connect already under way (a manual scan) counts as this attempt.
          await (_connecting ?? connect(device));
          if (connected) return;
        } catch (_) {
          // Still out of range: try again.
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _resetLink() async {
    _ready = false;
    final subs = List.of(_subs);
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
    _timeSync = _schedule = _control = null;
  }

  BluetoothCharacteristic _need(BluetoothCharacteristic? c) =>
      c != null && _ready ? c : throw StateError('The ${roleLabel == 'L' ? 'left' : 'right'} node is not connected.');

  /// Up to 8 round trips; the one with the shortest round trip wins. A lost
  /// reply skips that round. Replies are matched by the echoed send time, so
  /// a late reply to a timed-out round is never taken for the next one.
  @override
  Future<int> syncTime({int rounds = 8}) async {
    final ts = _need(_timeSync);
    return offsetUs = await estimateOffset(() async {
      final sent = DateTime.now().millisecondsSinceEpoch;
      final reply = ts.onValueReceived
          .map(TimeSyncReply.parse)
          .firstWhere((r) => r.tAppMs == sent & 0xffffffff)
          .timeout(const Duration(seconds: 1));
      try {
        await ts.write(encodeTimeSyncRequest(sent), withoutResponse: true);
      } catch (_) {
        reply.ignore();
        rethrow;
      }
      final r = await reply;
      return (sentMs: sent, nodeUs: r.tNodeUs, receivedMs: DateTime.now().millisecondsSinceEpoch);
    }, rounds: rounds);
  }

  @override
  Future<void> pushSchedule(int presetId, double bpm, List<(double, StepClass)> steps) async {
    final c = _need(_schedule);
    for (final chunk in encodeSchedule(presetId, bpm, steps)) {
      await c.write(chunk);
    }
  }

  Future<void> _cmd(List<int> bytes) => _need(_control).write(bytes);

  @override
  Future<void> start(Mode mode, int t0AppMs) => _cmd(encodeStart(mode, appMsToNodeUs(t0AppMs)));
  @override
  Future<void> stop() => _cmd(encodeCmd(Cmd.stop));
  @override
  Future<void> calibrate() => _cmd(encodeCmd(Cmd.calibrate));
  @override
  Future<void> cancelCalibration() => _cmd(encodeCmd(Cmd.calCancel));
  @override
  Future<void> buzzTest(Haptic h) => _cmd(encodeCmd(Cmd.buzzTest, [h.index]));
  @override
  Future<void> setThreshold(int conf) => _cmd(encodeCmd(Cmd.setThreshold, [conf]));
  @override
  Future<void> setWindow(int ms) => _cmd(encodeSetWindow(ms));

  @override
  Future<void> disconnect() async {
    _wanted = false;
    await _resetLink();
    await _device?.disconnect();
    notifyListeners();
  }
}

/// Bluetooth cannot be used right now; [message] says what the user can do.
class BleUnavailable implements Exception {
  const BleUnavailable(this.message, {this.adapterOff = false});
  final String message;

  /// Bluetooth is off (and could be turned on from the app on Android).
  final bool adapterOff;
  @override
  String toString() => message;
}

/// Both nodes. Scans for DT-L and DT-R and connects each. With `fake: true`
/// (build with --dart-define=FAKE_NODES=true) two simulated nodes are used.
class NodeManager extends ChangeNotifier {
  NodeManager({this.fake = false})
      : left = fake ? FakeNodeClient(Role.left) : BleNodeClient(Role.left),
        right = fake ? FakeNodeClient(Role.right) : BleNodeClient(Role.right) {
    for (final n in nodes) {
      n.addListener(notifyListeners);
    }
  }

  final bool fake;
  final NodeClient left;
  final NodeClient right;
  List<NodeClient> get nodes => [left, right];
  List<NodeClient> get connectedNodes => nodes.where((n) => n.connected).toList();

  /// Scans and connects each node as it is seen. The scan ends when both are
  /// found or after 8 s, so one node alone does not leave it hanging. Returns
  /// how many nodes are connected afterwards. Throws [BleUnavailable] when
  /// Bluetooth is off or not allowed.
  ///
  /// The scan filters by name only: the service UUID is in the nodes' scan
  /// response, and FBP ORs its filters, so adding it would not narrow the
  /// scan. [BleNodeClient.connect] checks the service and role instead.
  Future<int> scanAndConnect() async {
    if (fake) {
      for (final n in nodes) {
        if (!n.connected) await (n as FakeNodeClient).connect();
      }
      return connectedNodes.length;
    }
    await _ensureAdapterOn();
    final seen = <String>{};
    final connects = <Future<void>>[];
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        final node = switch (name) { 'DT-L' => left, 'DT-R' => right, _ => null } as BleNodeClient?;
        if (node == null || !seen.add(name) || node.connected) continue;
        // A failed connect is forgotten, so a later advertisement can retry it.
        connects.add(node.connect(r.device).catchError((Object _) => seen.remove(name)));
      }
      if (seen.length == 2) unawaited(FlutterBluePlus.stopScan());
    });
    try {
      await FlutterBluePlus.startScan(withNames: ['DT-L', 'DT-R'], timeout: const Duration(seconds: 8));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } on PlatformException catch (e) {
      throw BleUnavailable(_scanErrorMessage(e.message ?? e.code));
    } on FlutterBluePlusException catch (e) {
      throw BleUnavailable(_scanErrorMessage(e.description ?? '$e'));
    } finally {
      await sub.cancel();
    }
    await Future.wait(connects);
    return connectedNodes.length;
  }

  static String _scanErrorMessage(String raw) => raw.toLowerCase().contains('permission')
      ? 'Allow the Nearby devices (Bluetooth) permission in Settings, then scan again.'
      : 'Could not scan for the nodes ($raw).';

  Future<void> _ensureAdapterOn() async {
    if (!await FlutterBluePlus.isSupported) {
      throw const BleUnavailable('This device has no Bluetooth LE.');
    }
    final state = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.unknown);
    switch (state) {
      case BluetoothAdapterState.on:
        return;
      case BluetoothAdapterState.unauthorized:
        throw const BleUnavailable('Allow the Nearby devices (Bluetooth) permission in Settings, then scan again.');
      default:
        throw const BleUnavailable('Turn on Bluetooth to find the ankle nodes.', adapterOff: true);
    }
  }

  Future<void> syncAll() => Future.wait(connectedNodes.map((n) => n.syncTime()));
}
