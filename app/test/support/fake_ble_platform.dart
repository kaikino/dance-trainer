import 'dart:async';
import 'dart:typed_data';

import 'package:dance_trainer/ble/protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

/// A Bluetooth stack in memory, with Dance Trainer nodes behind it, so the
/// real [BleNodeClient] and [NodeManager] run in tests over FlutterBluePlus.
final class FakeBlePlatform extends FlutterBluePlusPlatform {
  final _scan = StreamController<BmScanResponse>.broadcast();
  final _conn = StreamController<BmConnectionStateResponse>.broadcast();
  final _services = StreamController<BmDiscoverServicesResult>.broadcast();
  final _received = StreamController<BmCharacteristicData>.broadcast();
  final _written = StreamController<BmCharacteristicData>.broadcast();
  final _descriptors = StreamController<BmDescriptorData>.broadcast();
  final _adapter = StreamController<BmBluetoothAdapterState>.broadcast();

  bool adapterOn = true;
  final connectCalls = <String>[];

  /// Role each device id reports in Status.
  final roles = <String, Role>{};

  /// Time-sync replies to drop (lost notifications), counted down.
  int dropSyncReplies = 0;

  /// The node's u32 µs clock is the app clock plus this.
  int nodeOffsetUs = 123456789;

  static final _svc = Guid(uuidService);

  @override
  Stream<BmScanResponse> get onScanResponse => _scan.stream;
  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged => _conn.stream;
  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices => _services.stream;
  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived => _received.stream;
  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => _written.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorWritten => _descriptors.stream;
  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged => _adapter.stream;

  /// FlutterBluePlus binds to the first platform it sees, so tests share one
  /// instance and reset it between tests.
  void reset() {
    adapterOn = true;
    connectCalls.clear();
    roles.clear();
    dropSyncReplies = 0;
  }

  /// Bluetooth switched on or off.
  void setAdapter(bool on) {
    adapterOn = on;
    _adapter.add(BmBluetoothAdapterState(adapterState: on ? BmAdapterStateEnum.on : BmAdapterStateEnum.off));
  }

  @override
  Future<bool> isSupported(BmIsSupportedRequest r) async => true;
  @override
  Future<BmBluetoothAdapterState> getAdapterState(BmBluetoothAdapterStateRequest r) async =>
      BmBluetoothAdapterState(adapterState: adapterOn ? BmAdapterStateEnum.on : BmAdapterStateEnum.off);
  @override
  Future<bool> setLogLevel(BmSetLogLevelRequest r) async => true;
  @override
  Future<bool> setOptions(BmSetOptionsRequest r) async => true;

  @override
  Future<bool> startScan(BmScanSettings s) async {
    if (!adapterOn) throw PlatformException(code: 'startScan', message: 'Bluetooth must be turned on');
    return true;
  }

  @override
  Future<bool> stopScan(BmStopScanRequest r) async => true;

  @override
  Future<bool> connect(BmConnectRequest r) async {
    connectCalls.add(r.remoteId.str);
    scheduleMicrotask(() => setConnected(r.remoteId, true));
    return true;
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest r) async {
    scheduleMicrotask(() => setConnected(r.remoteId, false));
    return true;
  }

  /// The link comes up or drops (as the radio would report it).
  void setConnected(DeviceIdentifier id, bool up) => _conn.add(BmConnectionStateResponse(
      remoteId: id,
      connectionState: up ? BmConnectionStateEnum.connected : BmConnectionStateEnum.disconnected,
      disconnectReasonCode: up ? null : 8,
      disconnectReasonString: up ? null : 'timeout'));

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest r) async {
    final props = BmCharacteristicProperties(
        broadcast: false,
        read: true,
        writeWithoutResponse: true,
        write: true,
        notify: true,
        indicate: false,
        authenticatedSignedWrites: false,
        extendedProperties: false,
        notifyEncryptionRequired: false,
        indicateEncryptionRequired: false);
    final chars = [
      for (final u in [uuidStatus, uuidTimeSync, uuidSchedule, uuidControl, uuidStepEvent, uuidStream])
        BmBluetoothCharacteristic(
            remoteId: r.remoteId,
            primaryServiceUuid: null,
            serviceUuid: _svc,
            characteristicUuid: Guid(u),
            instanceId: 0,
            descriptors: const [],
            properties: props),
    ];
    scheduleMicrotask(() => _services.add(BmDiscoverServicesResult(
        remoteId: r.remoteId,
        services: [BmBluetoothService(remoteId: r.remoteId, primaryServiceUuid: null, serviceUuid: _svc, characteristics: chars)],
        success: true,
        errorCode: 0,
        errorString: '')));
    return true;
  }

  @override
  Future<bool> readCharacteristic(BmReadCharacteristicRequest r) async {
    final role = roles[r.remoteId.str] ?? Role.left;
    scheduleMicrotask(() => notify(r.remoteId, uuidStatus, [protocolVersion, role.index, 3, 0, 80, 0, 3, 5, 3, 4]));
    return true;
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest r) async => false; // no CCCD write to wait for

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest r) async {
    scheduleMicrotask(() {
      _written.add(_data(r.remoteId, r.characteristicUuid.str128, r.value));
      if (r.characteristicUuid.str128 == uuidTimeSync) {
        if (dropSyncReplies > 0) {
          dropSyncReplies--;
          return;
        }
        final tApp = ByteData.sublistView(Uint8List.fromList(r.value)).getUint32(0, Endian.little);
        final nodeUs = (DateTime.now().microsecondsSinceEpoch + nodeOffsetUs) & 0xffffffff;
        final reply = ByteData(8)
          ..setUint32(0, tApp, Endian.little)
          ..setUint32(4, nodeUs, Endian.little);
        notify(r.remoteId, uuidTimeSync, reply.buffer.asUint8List());
      }
    });
    return true;
  }

  /// A notification from the node.
  void notify(DeviceIdentifier id, String uuid, List<int> value) => _received.add(_data(id, uuid, value));

  BmCharacteristicData _data(DeviceIdentifier id, String uuid, List<int> value) => BmCharacteristicData(
      remoteId: id,
      primaryServiceUuid: null,
      serviceUuid: _svc,
      characteristicUuid: Guid(uuid),
      instanceId: 0,
      value: value,
      success: true,
      errorCode: 0,
      errorString: '');

  void advertise(String id, String name) => _scan.add(BmScanResponse(advertisements: [
        BmScanAdvertisement(
            remoteId: DeviceIdentifier(id),
            platformName: name,
            advName: name,
            connectable: true,
            txPowerLevel: null,
            appearance: null,
            manufacturerData: const {},
            serviceData: const {},
            serviceUuids: const [],
            rssi: -50)
      ], success: true, errorCode: 0, errorString: ''));
}
