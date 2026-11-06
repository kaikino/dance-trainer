import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';

/// Live check of each node's calibration: one view per foot of a flat,
/// foot-shaped sole seen from behind and a little to the outside, with its
/// shadow on the floor. It turns and tilts with the foot, and is pushed off the
/// centre mark the way the foot is moving, further when faster.
///
/// Everything comes from the idle-mode Stream: the orientation quaternion
/// (calibrated sensor frame → world) and the foot-frame acceleration (+x toe,
/// +y outward on both feet, gravity removed). See docs/ble-protocol.md.
class LiveViewScreen extends StatefulWidget {
  const LiveViewScreen({super.key, required this.manager});
  final NodeManager manager;

  @override
  State<LiveViewScreen> createState() => _LiveViewScreenState();
}

class _LiveViewScreenState extends State<LiveViewScreen> {
  final _feet = <Role, _FootState>{};
  final _subs = <StreamSubscription<StreamBatch>>[];
  Timer? _frame;

  @override
  void initState() {
    super.initState();
    for (final n in widget.manager.nodes.where((n) => n.connected)) {
      final f = _feet[n.role] = _FootState(n);
      _subs.add(n.batches.listen(f.add));
    }
    widget.manager.addListener(_onChange);
    // Play the 50 Hz samples out at 50 Hz instead of jumping 5 at a time.
    _frame = Timer.periodic(const Duration(milliseconds: 20), (_) {
      var changed = false;
      for (final f in _feet.values) {
        changed |= f.step();
      }
      if (changed && mounted) setState(() {});
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _frame?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    widget.manager.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feet = [for (final r in Role.values) if (_feet[r] != null) _feet[r]!];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live view'),
        actions: [
          TextButton.icon(
            onPressed: () => setState(() {
              for (final f in feet) {
                f.zeroHeading();
              }
            }),
            icon: const Icon(Icons.navigation),
            label: const Text('Set straight ahead'),
          ),
        ],
      ),
      body: feet.isEmpty
          ? const Center(child: Text('No node connected.'))
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Stand with your toes pointing forward and tap Set straight ahead. Turn your toe, '
                    'lift it, roll onto an edge: the foot on screen should copy you. Slide or kick: the '
                    'foot moves off the centre mark the way it is going, further when faster.',
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final panels = [for (final f in feet) Expanded(child: _FootPanel(foot: f))];
                      return c.maxWidth > c.maxHeight
                          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: panels)
                          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: panels);
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// One node's latest pose, smoothed.
class _FootState {
  _FootState(this.node);
  final NodeClient node;

  final _queue = <StreamSample>[];
  bool _seen = false;
  double _refYaw = 0;
  bool _zeroPending = true;

  /// Toe heading relative to straight ahead, + = toward the dancer's left.
  double heading = 0;

  /// Toe raised; the dancer's-left edge raised. Radians.
  double toeUp = 0, leftEdgeUp = 0;

  /// Foot frame → world with the heading made relative to straight ahead.
  List<List<double>> pose = const [
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
  ];

  /// Estimated velocity along the floor, m/s: forward and toward the dancer's left.
  /// Integrated from acceleration, so it drifts; it leaks back to zero and is
  /// reset whenever the foot has been still for [_stillSamples] samples.
  double velFwd = 0, velLeft = 0;
  int _still = 0;
  static const _dt = 0.02; // idle-mode Stream: 50 Hz
  static const _stillG = 0.06, _stillSamples = 5, _leakS = 0.6;

  bool get left => node.role == Role.left;
  bool get seen => _seen;

  /// Toe turned outward, outer edge raised.
  double get turnOut => left ? heading : -heading;
  double get outerEdgeUp => left ? leftEdgeUp : -leftEdgeUp;

  void add(StreamBatch b) {
    // Capture mode streams the sensor frame instead; nothing here makes sense then.
    if (node.status?.mode == Mode.capture) return;
    _queue.addAll(b.samples.where((s) => !s.isGyro));
    if (_queue.length > 15) _queue.removeRange(0, _queue.length - 5);
  }

  void zeroHeading() => _zeroPending = true;

  /// Applies the next queued sample. Returns false when there was none.
  bool step() {
    if (_queue.isEmpty) return false;
    final s = _queue.removeAt(0);
    final m = _matrix(s.qw, s.qx, s.qy, s.qz);
    // Columns of m: where the toe (+x) and the left side (+y) point in the world.
    final yaw = atan2(m[1][0], m[0][0]);
    if (_zeroPending) {
      _refYaw = yaw;
      _zeroPending = false;
    }
    heading = atan2(sin(yaw - _refYaw), cos(yaw - _refYaw));
    toeUp = asin(m[2][0].clamp(-1.0, 1.0));
    leftEdgeUp = asin(m[2][1].clamp(-1.0, 1.0));
    final c = cos(-_refYaw), sn = sin(-_refYaw);
    pose = [
      [for (var j = 0; j < 3; j++) c * m[0][j] - sn * m[1][j]],
      [for (var j = 0; j < 3; j++) sn * m[0][j] + c * m[1][j]],
      m[2],
    ];

    // Foot frame → world: the stream's y is outward on both feet, so un-mirror
    // it to "toward the dancer's left", then turn by the heading.
    final fx = s.ax / 1000, fy = (left ? 1 : -1) * s.ay / 1000;
    final wx = cos(heading) * fx - sin(heading) * fy;
    final wy = sin(heading) * fx + cos(heading) * fy;
    if (sqrt(wx * wx + wy * wy) < _stillG) {
      _still++;
    } else {
      _still = 0;
    }
    if (_still >= _stillSamples) {
      velFwd = velLeft = 0;
    } else {
      final leak = exp(-_dt / _leakS);
      velFwd = (velFwd + wx * 9.81 * _dt) * leak;
      velLeft = (velLeft + wy * 9.81 * _dt) * leak;
    }
    _seen = true;
    return true;
  }

  /// Rotation matrix of q, the same as q_rotate() in firmware fusion.c.
  static List<List<double>> _matrix(double w, double x, double y, double z) => [
        [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
        [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
        [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
      ];
}

class _FootPanel extends StatelessWidget {
  const _FootPanel({required this.foot});
  final _FootState foot;

  static String _deg(double r) => '${(r * 180 / pi).abs().round()}°';

  /// "turned 12° out", or null when within 3° of zero.
  static String? _angle(double r, String pos, String neg) =>
      r.abs() < 3 * pi / 180 ? null : '${_deg(r)} ${r > 0 ? pos : neg}';

  @override
  Widget build(BuildContext context) {
    final st = foot.node.status;
    final theme = Theme.of(context);
    final (badge, color) = switch (st) {
      null || Status(calFlags: null) => ('Calibration unknown (old firmware)', Colors.grey),
      Status(boardMoved: true) => ('Board moved on the strap? Calibrate again', Colors.orange),
      Status(knowsForward: true) => ('Calibrated', Colors.green),
      Status(calibrated: true) => ('Tilt only: toe direction unknown, calibrate again', Colors.orange),
      _ => ('Not calibrated: directions follow the board, not the foot', Colors.red),
    };
    final parts = [
      if (_angle(foot.turnOut, 'out', 'in') case final s?) 'toe turned $s',
      if (_angle(foot.toeUp, 'up', 'down') case final s?) 'toe $s',
      if (_angle(foot.outerEdgeUp, 'up', 'down') case final s?) 'outer edge $s',
    ];
    final speed = sqrt(foot.velFwd * foot.velFwd + foot.velLeft * foot.velLeft);
    if (speed >= _FootPainter.minSpeed) parts.add('moving ${speed.toStringAsFixed(1)} m/s');
    final caption = !foot.seen
        ? 'Waiting for data…'
        : parts.isEmpty
            ? 'Flat, toe straight ahead'
            : parts.join(' · ');
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(foot.left ? 'Left ankle' : 'Right ankle', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(badge, style: TextStyle(color: color), overflow: TextOverflow.ellipsis)),
              ],
            ),
            Expanded(child: CustomPaint(painter: _FootPainter(foot, theme), size: Size.infinite)),
            Center(child: Text(caption, style: theme.textTheme.bodyLarge)),
          ],
        ),
      ),
    );
  }
}

typedef _V3 = (double, double, double);

/// The foot as a flat sole (+x toe, +y the dancer's left, +z up; length 1),
/// rotated by the foot's pose and lifted above the floor so it can tilt, with
/// its shadow flat on the floor. Orthographic camera behind the dancer, raised
/// and a little to the outside of this foot.
class _FootPainter extends CustomPainter {
  _FootPainter(this.foot, this.theme);
  final _FootState foot;
  final ThemeData theme;

  static const lift = 0.22, thick = 0.07;

  /// Speed that moves the foot all the way to the ring, m/s; the ring's radius
  /// in foot lengths; speeds below minSpeed draw the foot centred.
  static const fullSpeed = 1.0, reach = 0.3, minSpeed = 0.05;

  /// Sole outline, convex: rounded heel, wider at the ball.
  static final List<(double, double)> outline = () {
    double halfWidth(double x) {
      final u = 2 * x; // −1 heel … +1 toe
      return (0.13 + 0.05 * (u + 1) / 2) * sqrt(max(0.0, 1 - u * u));
    }

    // Denser near heel and toe so the ends come out round.
    const n = 32;
    final xs = [for (var i = 0; i <= n; i++) -0.5 * cos(pi * i / n)];
    return [
      for (final x in xs) (x, halfWidth(x)),
      for (final x in xs.reversed.skip(1).take(n - 1)) (x, -halfWidth(x)),
    ];
  }();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final m = foot.pose;
    final outside = foot.left ? 1.0 : -1.0; // +y is outside on the left foot
    // d = viewing direction; r = screen right; u = screen up.
    const el = 30 * pi / 180;
    final az = -outside * 15 * pi / 180;
    final d = (cos(el) * cos(az), cos(el) * sin(az), -sin(el));
    final r = (sin(az), -cos(az), 0.0);
    final u = _cross(r, d);
    final scale = min(size.width * 0.5, size.height * 0.75);
    final c = Offset(size.width / 2, size.height * 0.58);
    Offset proj(_V3 p) => c + Offset(_dot(p, r), -_dot(p, u)) * scale;

    // Offset from the centre mark: velocity along the floor, (forward, left).
    var ox = foot.velFwd / fullSpeed, oy = foot.velLeft / fullSpeed;
    final od = sqrt(ox * ox + oy * oy);
    if (od * fullSpeed < minSpeed) {
      ox = oy = 0;
    } else if (od > 1) {
      ox /= od;
      oy /= od;
    }
    final offset = (ox * reach, oy * reach);

    _V3 world((double, double) p, double z) {
      final v = (p.$1, p.$2, z);
      return (
        m[0][0] * v.$1 + m[0][1] * v.$2 + m[0][2] * v.$3 + offset.$1,
        m[1][0] * v.$1 + m[1][1] * v.$2 + m[1][2] * v.$3 + offset.$2,
        m[2][0] * v.$1 + m[2][1] * v.$2 + m[2][2] * v.$3 + lift,
      );
    }

    final cs = theme.colorScheme;
    final guide = Paint()
      ..color = cs.outlineVariant
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Floor: the ring the foot moves out to at full speed, and the straight-ahead line.
    canvas.drawPath(
        Path()
          ..addPolygon(
              [for (var a = 0; a <= 360; a += 10) proj((reach * cos(a * pi / 180), reach * sin(a * pi / 180), 0))],
              true),
        guide);
    canvas.drawLine(proj((-0.65, 0, 0)), proj((0.75, 0, 0)), guide);
    canvas.drawPath(
        Path()..addPolygon([proj((0.85, 0, 0)), proj((0.75, 0.05, 0)), proj((0.75, -0.05, 0))], true),
        Paint()..color = cs.outlineVariant);

    // Shadow: the sole's outline dropped straight down to the floor.
    final shadow = [for (final p in outline) world(p, 0)];
    canvas.drawPath(Path()..addPolygon([for (final p in shadow) proj((p.$1, p.$2, 0))], true),
        Paint()..color = cs.onSurface.withValues(alpha: 0.12));

    // Sole: a convex slab, so drawing only the faces toward the camera is enough.
    final top = [for (final p in outline) world(p, thick / 2)];
    final bottom = [for (final p in outline) world(p, -thick / 2)];
    _V3 normal(_V3 v) => (
          m[0][0] * v.$1 + m[0][1] * v.$2 + m[0][2] * v.$3,
          m[1][0] * v.$1 + m[1][1] * v.$2 + m[1][2] * v.$3,
          m[2][0] * v.$1 + m[2][1] * v.$2 + m[2][2] * v.$3,
        );
    bool facing(_V3 n) => _dot(n, d) < 0;
    final side = Paint()..color = Color.lerp(cs.primary, Colors.black, 0.35)!;
    for (var i = 0; i < outline.length; i++) {
      final j = (i + 1) % outline.length;
      final a = outline[i], b = outline[j];
      final mx = (a.$1 + b.$1) / 2, my = (a.$2 + b.$2) / 2;
      // Outward normal: perpendicular to the edge, away from the middle.
      var nx = b.$2 - a.$2, ny = a.$1 - b.$1;
      if (nx * mx + ny * my < 0) {
        nx = -nx;
        ny = -ny;
      }
      if (!facing(normal((nx, ny, 0)))) continue;
      canvas.drawPath(Path()..addPolygon([proj(top[i]), proj(top[j]), proj(bottom[j]), proj(bottom[i])], true), side);
    }
    final topUp = facing(normal((0, 0, 1)));
    final face = topUp ? top : bottom;
    canvas.drawPath(Path()..addPolygon([for (final p in face) proj(p)], true),
        Paint()..color = topUp ? cs.primary : Color.lerp(cs.primary, Colors.black, 0.5)!);

    // Toe chevron on the top so the direction reads at a glance.
    if (topUp) {
      Offset at(double x, double y) => proj(world((x, y), thick / 2));
      final a = at(0.18, 0.09), b = at(0.34, 0), e = at(0.18, -0.09);
      canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(e.dx, e.dy),
        Paint()
          ..color = cs.onPrimary
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(2.0, scale * 0.025)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  static double _dot(_V3 a, _V3 b) => a.$1 * b.$1 + a.$2 * b.$2 + a.$3 * b.$3;
  static _V3 _cross(_V3 a, _V3 b) =>
      (a.$2 * b.$3 - a.$3 * b.$2, a.$3 * b.$1 - a.$1 * b.$3, a.$1 * b.$2 - a.$2 * b.$1);

  @override
  bool shouldRepaint(_FootPainter old) => true;
}
