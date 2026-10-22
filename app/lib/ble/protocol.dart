// Wire format for the Dance Trainer BLE service. Mirrors docs/ble-protocol.md
// and firmware/components/common/include/dt_protocol.h. Change all three together.
import 'dart:typed_data';

const int protocolVersion = 1;

String dtUuid(int short) =>
    '7d4e${short.toRadixString(16).padLeft(4, '0')}-5a1c-4b8e-9f3a-2c6d8e1f0a00';

final String uuidService = dtUuid(0x0001);
final String uuidStatus = dtUuid(0x0002);
final String uuidTimeSync = dtUuid(0x0003);
final String uuidSchedule = dtUuid(0x0004);
final String uuidControl = dtUuid(0x0005);
final String uuidStepEvent = dtUuid(0x0006);
final String uuidStream = dtUuid(0x0007);

enum StepClass { none, inPlace, forward, back, sideOut, cross, kick }

enum Verdict { unjudged, correct, offBeat, wrongStep, missed, extra }

enum Mode { idle, capture, dance }

enum Role { left, right }

enum Haptic { none, short, double, long }

enum Cmd { none, start, stop, calibrate, buzzTest, setThreshold, setWindow, selftest }

/// JSON name ↔ StepClass, as used in presets/*.json.
const stepClassNames = {
  'none': StepClass.none,
  'in_place': StepClass.inPlace,
  'forward': StepClass.forward,
  'back': StepClass.back,
  'side_out': StepClass.sideOut,
  'cross': StepClass.cross,
  'kick': StepClass.kick,
};

const schedFlagHeader = 0x01;
const schedFlagLast = 0x02;

class Status {
  final int protocolVersion, fwVersion, batteryPct;
  final Role role;
  final Mode mode;
  Status(this.protocolVersion, this.role, this.fwVersion, this.batteryPct, this.mode);

  static Status parse(List<int> b) {
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return Status(
      d.getUint8(0),
      Role.values[d.getUint8(1)],
      d.getUint16(2, Endian.little),
      d.getUint8(4),
      Mode.values[d.getUint8(5)],
    );
  }

  @override
  String toString() =>
      'fw ${fwVersion >> 8}.${fwVersion & 0xff}  bat $batteryPct%  ${mode.name}';
}

class TimeSyncReply {
  final int tAppMs, tNodeUs;
  TimeSyncReply(this.tAppMs, this.tNodeUs);
  static TimeSyncReply parse(List<int> b) {
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return TimeSyncReply(d.getUint32(0, Endian.little), d.getUint32(4, Endian.little));
  }
}

Uint8List encodeTimeSyncRequest(int tAppMs) =>
    (ByteData(4)..setUint32(0, tAppMs & 0xffffffff, Endian.little)).buffer.asUint8List();

class StepEvent {
  final int seq, tStrikeNodeUs, confidence, timingErrMs;
  final StepClass stepClass, expectedClass;
  final Verdict verdict;
  StepEvent(this.seq, this.tStrikeNodeUs, this.stepClass, this.confidence,
      this.expectedClass, this.timingErrMs, this.verdict);

  static StepEvent parse(List<int> b) {
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return StepEvent(
      d.getUint16(0, Endian.little),
      d.getUint32(2, Endian.little),
      StepClass.values[d.getUint8(6)],
      d.getUint8(7),
      StepClass.values[d.getUint8(8)],
      d.getInt16(9, Endian.little),
      Verdict.values[d.getUint8(11)],
    );
  }
}

class StreamSample {
  final double qw, qx, qy, qz; // unit quaternion
  final int ax, ay, az; // mg (or dps×10 when isGyro)
  final bool isGyro;
  StreamSample(this.qw, this.qx, this.qy, this.qz, this.ax, this.ay, this.az, this.isGyro);
}

class StreamBatch {
  static const samplesPerBatch = 5;
  static const sampleBytes = 14;
  final int t0NodeUs;
  final List<StreamSample> samples;
  StreamBatch(this.t0NodeUs, this.samples);

  static StreamBatch parse(List<int> b) {
    final d = ByteData.sublistView(Uint8List.fromList(b));
    final t0 = d.getUint32(0, Endian.little);
    final out = <StreamSample>[];
    for (var i = 0; i < samplesPerBatch; i++) {
      final o = 4 + i * sampleBytes;
      final qwRaw = d.getInt16(o, Endian.little);
      out.add(StreamSample(
        qwRaw / 16384.0,
        d.getInt16(o + 2, Endian.little) / 16384.0,
        d.getInt16(o + 4, Endian.little) / 16384.0,
        d.getInt16(o + 6, Endian.little) / 16384.0,
        d.getInt16(o + 8, Endian.little),
        d.getInt16(o + 10, Endian.little),
        d.getInt16(o + 12, Endian.little),
        qwRaw == 0x7fff,
      ));
    }
    return StreamBatch(t0, out);
  }
}

/// Builds the chunked Schedule writes for one node. `steps` is already filtered
/// to this node's foot. Each entry: (beat, class).
List<Uint8List> encodeSchedule(int presetId, double bpm, List<(double, StepClass)> steps) {
  const maxPerChunk = 80;
  final chunks = <Uint8List>[];
  final header = ByteData(7)
    ..setUint8(0, schedFlagHeader | (steps.isEmpty ? schedFlagLast : 0))
    ..setUint16(1, presetId, Endian.little)
    ..setUint16(3, (bpm * 10).round(), Endian.little)
    ..setUint16(5, steps.length, Endian.little);
  chunks.add(header.buffer.asUint8List());
  for (var i = 0; i < steps.length; i += maxPerChunk) {
    final part = steps.sublist(i, (i + maxPerChunk).clamp(0, steps.length));
    final last = i + maxPerChunk >= steps.length;
    final d = ByteData(1 + 3 * part.length)..setUint8(0, last ? schedFlagLast : 0);
    for (var j = 0; j < part.length; j++) {
      d.setUint16(1 + 3 * j, (part[j].$1 * 100).round(), Endian.little);
      d.setUint8(3 + 3 * j, part[j].$2.index);
    }
    chunks.add(d.buffer.asUint8List());
  }
  return chunks;
}

Uint8List encodeStart(Mode mode, int t0NodeUs) => (ByteData(6)
      ..setUint8(0, Cmd.start.index)
      ..setUint8(1, mode.index)
      ..setUint32(2, t0NodeUs & 0xffffffff, Endian.little))
    .buffer
    .asUint8List();

Uint8List encodeCmd(Cmd cmd, [List<int> args = const []]) =>
    Uint8List.fromList([cmd.index, ...args]);

Uint8List encodeSetWindow(int ms) =>
    (ByteData(3)..setUint8(0, Cmd.setWindow.index)..setUint16(1, ms, Endian.little))
        .buffer
        .asUint8List();
