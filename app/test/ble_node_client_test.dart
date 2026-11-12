import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ble_platform.dart';

/// The real BleNodeClient and NodeManager over an in-memory Bluetooth stack.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final p = FakeBlePlatform();
  FlutterBluePlusPlatform.instance = p;
  const leftId = DeviceIdentifier('AA:00:00:00:00:01');
  const rightId = DeviceIdentifier('AA:00:00:00:00:02');
  final stepEvent = [0x01, 0x00, 0x40, 0xE2, 0x01, 0x00, 0x02, 0xA0, 0x02, 0x00, 0x00, 0x01];

  setUp(() => p
    ..reset()
    ..roles.addAll({leftId.str: Role.left, rightId.str: Role.right}));

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('a reconnect does not deliver each notification twice', () async {
    final node = BleNodeClient(Role.left);
    final events = <StepEvent>[];
    node.events.listen(events.add);
    final device = BluetoothDevice(remoteId: leftId);

    await node.connect(device);
    expect(node.connected, isTrue);
    p.setConnected(leftId, false); // the link drops
    await settle();
    expect(node.connected, isFalse);
    await node.connect(device); // and comes back
    expect(node.connected, isTrue);

    p.notify(leftId, uuidStepEvent, stepEvent);
    await settle();
    expect(events, hasLength(1));
    await node.disconnect();
  });

  test('a node reporting the other foot is refused and left disconnected', () async {
    final node = BleNodeClient(Role.left);
    await expectLater(node.connect(BluetoothDevice(remoteId: rightId)), throwsA(isA<NotADanceNode>()));
    expect(node.connected, isFalse);
    // Nothing left listening: a notification from it goes nowhere.
    final events = <StepEvent>[];
    node.events.listen(events.add);
    p.notify(rightId, uuidStepEvent, stepEvent);
    await settle();
    expect(events, isEmpty);
    expect(() => node.stop(), throwsStateError);
  });

  test('clock sync over BLE survives lost replies', () async {
    final node = BleNodeClient(Role.left);
    await node.connect(BluetoothDevice(remoteId: leftId));
    // The first two replies are lost; their 1 s timeouts are skipped.
    p.dropSyncReplies = 2;
    final offset = await node.syncTime(rounds: 4);
    final want = p.nodeOffsetUs;
    expect(((offset - want) & 0xffffffff), anyOf(lessThan(20000), greaterThan(0x100000000 - 20000)));
    await node.disconnect();
  });

  test('scanning with Bluetooth off says so, and the next scan connects each node once', () async {
    final m = NodeManager();
    p.setAdapter(false);
    await expectLater(
        m.scanAndConnect(), throwsA(isA<BleUnavailable>().having((e) => e.adapterOff, 'adapterOff', isTrue)));

    p.setAdapter(true);
    final scan = m.scanAndConnect();
    await settle();
    p.advertise(leftId.str, 'DT-L');
    p.advertise(rightId.str, 'DT-R');
    expect(await scan.timeout(const Duration(seconds: 10)), 2);
    expect(p.connectCalls, [leftId.str, rightId.str]);
    await (m.left as BleNodeClient).disconnect();
    await (m.right as BleNodeClient).disconnect();
  });
}
