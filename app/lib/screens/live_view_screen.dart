import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../ui/foot_shape.dart';
import '../ui/style.dart';

/// Live check of each node's calibration: one view per foot of a flat,
/// foot-shaped sole seen from behind and a little to the outside, with its
/// shadow on the floor, over a fixed grid. It turns and tilts with the foot,
/// and a damped spring driven by the measured acceleration pushes it off
/// centre the way the foot is pushed.
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
  Timer? _frame, _speak;

  /// What a screen reader hears per foot, refreshed once a second rather than
  /// at the 50 Hz the picture moves (which kept the accessibility tree busy).
  final _spoken = <Role, String>{};

  @override
  void initState() {
    super.initState();
    _addFeet();
    widget.manager.addListener(_onChange);
    // Play the samples out at their own rate instead of jumping 5 at a time.
    _frame = Timer.periodic(Duration(microseconds: StreamBatch.sampleUs(Mode.idle).round()), (_) {
      var changed = false;
      for (final f in _feet.values) {
        changed |= f.step();
      }
      if (changed && mounted) setState(() {});
    });
    _speak = Timer.periodic(const Duration(seconds: 1), (_) => _updateSpoken());
    _updateSpoken();
  }

  /// A view for every connected node not shown yet: one that connects (or
  /// reconnects) after the screen opened gets its foot too.
  void _addFeet() {
    for (final n in widget.manager.nodes.where((n) => n.connected)) {
      if (_feet.containsKey(n.role)) continue;
      final f = _feet[n.role] = _FootState(n);
      _subs.add(n.batches.listen(f.add));
    }
  }

  void _updateSpoken() {
    var changed = false;
    for (final f in _feet.values) {
      final caption = _FootPanel.caption(f);
      if (_spoken[f.node.role] != caption) {
        _spoken[f.node.role] = caption;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _onChange() {
    _addFeet();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _frame?.cancel();
    _speak?.cancel();
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Toes forward, tap Set straight ahead. Then move your foot: the one on screen should copy you.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final panels = [
                        for (final f in feet) Expanded(child: _FootPanel(foot: f, spoken: _spoken[f.node.role] ?? '')),
                      ];
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

/// One node's latest pose, plus the spring push.
class _FootState {
  _FootState(this.node);
  final NodeClient node;

  /// Samples waiting to be shown, each with the spring push up to it.
  /// Integration happens on arrival so no sample is ever skipped; only the
  /// display queue is trimmed when it falls behind.
  final _queue = <(StreamSample, double, double)>[];
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

  /// Spring push: how far the foot is drawn off centre, in foot lengths,
  /// forward and toward the dancer's left. The foot is a mass on a critically
  /// damped spring driven by the measured floor-plane acceleration, so it
  /// leans the way it is pushed and settles back without drifting or bouncing.
  /// No velocity is estimated.
  double pushFwd = 0, pushLeft = 0;

  // Spring state, stepped per sample on arrival.
  double _pF = 0, _pL = 0, _dpF = 0, _dpL = 0;
  double _biasF = 0, _biasL = 0; // g, learned while still
  double _stillFor = 0; // s
  int? _lastUs;
  (double, double, double, double)? _lastQ;

  /// Still = horizontal and vertical acceleration under [_stillG] and rotation
  /// under [_stillDps], held for [_stillHoldS]. While still the acceleration
  /// bias (leftover gravity from small tilt errors) is learned and removed.
  static const _stillG = 0.05, _stillDps = 20.0, _stillHoldS = 0.2;

  /// Spring natural frequency (rad/s, about 1.5 Hz) and the push for a steady
  /// 1 g, in foot lengths. Acceleration under [_deadG] is ignored.
  static const _omega = 2 * pi * 1.5, _perG = 2.5, _deadG = 0.03;

  bool get left => node.role == Role.left;
  bool get seen => _seen;

  /// Toe turned outward, outer edge raised.
  double get turnOut => left ? heading : -heading;
  double get outerEdgeUp => left ? leftEdgeUp : -leftEdgeUp;

  void add(StreamBatch b) {
    // Capture mode streams the sensor frame instead; nothing here makes sense then.
    if (node.status?.mode == Mode.capture) return;
    final acc = b.samples.where((s) => !s.isGyro).toList();
    for (var i = 0; i < acc.length; i++) {
      final s = acc[i];
      _integrate(s, (b.t0NodeUs + (i * StreamBatch.sampleUs(Mode.idle)).round()) & 0xffffffff);
      _queue.add((s, _pF, _pL));
    }
    if (_queue.length > 15) _queue.removeRange(0, _queue.length - 5);
  }

  void _integrate(StreamSample s, int tUs) {
    final last = _lastUs;
    _lastUs = tUs;
    final q = (s.qw, s.qx, s.qy, s.qz);
    final lastQ = _lastQ;
    _lastQ = q;
    if (last == null || lastQ == null) return;
    final dt = ((tUs - last) & 0xffffffff) / 1e6;
    if (dt <= 0 || dt > 0.2) {
      // Gap in the stream: start the spring over.
      _pF = _pL = _dpF = _dpL = 0;
      return;
    }

    // Horizontal acceleration in the world, relative to straight ahead. The
    // stream's y is outward on both feet; un-mirror it to "toward the left".
    final m = _matrix(s.qw, s.qx, s.qy, s.qz);
    final h = atan2(m[1][0], m[0][0]) - _refYaw;
    final fx = s.ax / 1000, fy = (left ? 1 : -1) * s.ay / 1000, fz = s.az / 1000;
    final ax = cos(h) * fx - sin(h) * fy, ay = sin(h) * fx + cos(h) * fy;

    // Rotation rate from consecutive orientations.
    final dot = (q.$1 * lastQ.$1 + q.$2 * lastQ.$2 + q.$3 * lastQ.$3 + q.$4 * lastQ.$4).abs().clamp(0.0, 1.0);
    final dps = 2 * acos(dot) * 180 / pi / dt;

    final quiet = sqrt(ax * ax + ay * ay) < _stillG && fz.abs() < _stillG && dps < _stillDps;
    _stillFor = quiet ? _stillFor + dt : 0;
    if (_stillFor >= _stillHoldS) {
      _biasF += 0.05 * (ax - _biasF);
      _biasL += 0.05 * (ay - _biasL);
    }
    var uF = ax - _biasF, uL = ay - _biasL;
    final mag = sqrt(uF * uF + uL * uL);
    if (mag < _deadG) {
      uF = uL = 0;
    } else {
      // Shrink by the dead band so the push starts from zero, not with a jump.
      final k = (mag - _deadG) / mag;
      uF *= k;
      uL *= k;
    }
    // p'' = K·a − ω²·p − 2ω·p' (critically damped), semi-implicit Euler.
    const w = _omega, k = _perG * _omega * _omega;
    _dpF += (k * uF - w * w * _pF - 2 * w * _dpF) * dt;
    _dpL += (k * uL - w * w * _pL - 2 * w * _dpL) * dt;
    _pF += _dpF * dt;
    _pL += _dpL * dt;
  }

  void zeroHeading() => _zeroPending = true;

  /// Applies the next queued sample. Returns false when there was none.
  bool step() {
    if (_queue.isEmpty) return false;
    final (s, pF, pL) = _queue.removeAt(0);
    final m = _matrix(s.qw, s.qx, s.qy, s.qz);
    // Columns of m: where the toe (+x) and the left side (+y) point in the world.
    final yaw = atan2(m[1][0], m[0][0]);
    if (_zeroPending) {
      // The push so far was relative to the old straight ahead.
      _refYaw = yaw;
      _zeroPending = false;
      _pF = _pL = _dpF = _dpL = 0;
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
    pushFwd = pF;
    pushLeft = pL;
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
  const _FootPanel({required this.foot, required this.spoken});
  final _FootState foot;

  /// [caption] as of the last once-a-second refresh, for screen readers.
  final String spoken;

  static String _deg(double r) => '${(r * 180 / pi).abs().round()}°';

  /// "turned 12° out", or null when within 3° of zero.
  static String? _angle(double r, String pos, String neg) =>
      r.abs() < 3 * pi / 180 ? null : '${_deg(r)} ${r > 0 ? pos : neg}';

  /// How the foot is posed, in words.
  static String caption(_FootState foot) {
    final parts = [
      if (_angle(foot.turnOut, 'out', 'in') case final s?) 'toe turned $s',
      if (_angle(foot.toeUp, 'up', 'down') case final s?) 'toe $s',
      if (_angle(foot.outerEdgeUp, 'up', 'down') case final s?) 'outer edge $s',
    ];
    return !foot.node.connected
        ? 'Disconnected. Go back and scan again.'
        : !foot.seen
            ? 'Waiting for data…'
            : parts.isEmpty
                ? 'Flat, toe straight ahead'
                : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final st = foot.node.status;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (badge, color) = foot.node.connected
        ? switch (calStateOf(st)) {
            CalState.unknown => ('Calibration unknown (old firmware)', scheme.onSurfaceVariant),
            CalState.boardMoved => ('Board moved on the strap? Calibrate again', warnColor(context)),
            CalState.calibrated => ('Calibrated', okColor(context)),
            CalState.tiltOnly => ('Tilt only: toe direction unknown, calibrate again', warnColor(context)),
            CalState.notCalibrated => ('Not calibrated: directions follow the board, not the foot', scheme.error),
          }
        : ('Disconnected', scheme.error);
    final captionStyle = theme.textTheme.titleMedium?.copyWith(height: 1.4);
    final name = '${footName(foot.node.role)} ankle';
    return Semantics(
      container: true,
      label: '$name. $badge. $spoken',
      excludeSemantics: true,
      child: Card(
        margin: const EdgeInsets.all(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(name, style: theme.textTheme.titleMedium),
                  const SizedBox(width: 12),
                  Icon(Icons.circle, size: 10, color: color),
                  const SizedBox(width: 6),
                  Expanded(child: Text(badge, style: TextStyle(color: color), overflow: TextOverflow.ellipsis)),
                ],
              ),
              Expanded(
                // A dropped node: the last pose, greyed out.
                child: Opacity(
                  opacity: foot.node.connected ? 1 : 0.3,
                  child: CustomPaint(painter: _FootPainter(foot, theme), size: Size.infinite),
                ),
              ),
              // Two lines reserved (at the user's text size) so the panel does
              // not jump as the caption changes.
              SizedBox(
                height: MediaQuery.textScalerOf(context).scale(captionStyle?.fontSize ?? 16) * 1.4 * 2,
                child: Center(
                  child: Text(caption(foot),
                      textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: captionStyle),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _V3 = (double, double, double);

/// The foot as a flat sole (+x toe, +y the dancer's left, +z up; length 1),
/// rotated by the foot's pose and lifted above the floor so it can tilt, with
/// its shadow flat on the floor. The sole is a real foot's shape (arch on the
/// inner side, mirrored per foot) with a coloured toe cap. Orthographic camera
/// behind the dancer, high (55°) so a turned-out toe is not exaggerated, and a
/// little to the outside of this foot.
class _FootPainter extends CustomPainter {
  _FootPainter(this.foot, this.theme);
  final _FootState foot;
  final ThemeData theme;

  static const lift = 0.22, thick = 0.07;

  /// Furthest the push can draw the foot off centre, foot lengths. Larger
  /// pushes are squeezed softly toward it rather than cut off.
  static const reach = 0.4;

  /// Sole outlines per foot; the inner side has the arch.
  static final _left = soleOutline(left: true), _right = soleOutline(left: false);

  /// The toe cap starts this far toward the toe.
  static const capFrom = 0.3;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final m = foot.pose;
    final outline = foot.left ? _left : _right;
    final outside = foot.left ? 1.0 : -1.0; // +y is outside on the left foot
    // d = viewing direction; r = screen right; u = screen up.
    const el = 55 * pi / 180;
    final az = -outside * 15 * pi / 180;
    final d = (cos(el) * cos(az), cos(el) * sin(az), -sin(el));
    final r = (sin(az), -cos(az), 0.0);
    final u = _cross(r, d);
    final scale = min(size.width * 0.55, size.height * 0.8);
    final c = Offset(size.width / 2, size.height * 0.55);
    Offset proj(_V3 p) => c + Offset(_dot(p, r), -_dot(p, u)) * scale;

    // Offset from the centre: the spring push, (forward, left).
    final pd = sqrt(foot.pushFwd * foot.pushFwd + foot.pushLeft * foot.pushLeft);
    final squeeze = pd < 1e-6 ? 0.0 : reach * _tanh(pd / reach) / pd;
    final offset = (foot.pushFwd * squeeze, foot.pushLeft * squeeze);

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

    // Floor: a grid fixed in the world (a square every 0.15 foot lengths), so
    // the foot's turn and its displacement both read against straight lines,
    // and a bolder straight-ahead line with an arrow.
    final grid = Paint()
      ..color = cs.outlineVariant.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    const cell = 0.15, gx0 = -0.6, gx1 = 0.75, gy = 0.6;
    for (var x = gx0; x <= gx1 + 1e-9; x += cell) {
      canvas.drawLine(proj((x, -gy, 0)), proj((x, gy, 0)), grid);
    }
    for (var y = -gy; y <= gy + 1e-9; y += cell) {
      canvas.drawLine(proj((gx0, y, 0)), proj((gx1, y, 0)), grid);
    }
    canvas.drawLine(proj((gx0, 0, 0)), proj((gx1 + 0.05, 0, 0)), guide..strokeWidth = 2);
    canvas.drawPath(
        Path()..addPolygon([proj((gx1 + 0.17, 0, 0)), proj((gx1 + 0.05, 0.06, 0)), proj((gx1 + 0.05, -0.06, 0))], true),
        Paint()..color = cs.outline);

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
    // Winding of the outline, so each edge's outward normal is known even in
    // the arch (the outline is not convex there).
    var area2 = 0.0;
    for (var i = 0; i < outline.length; i++) {
      final a = outline[i], b = outline[(i + 1) % outline.length];
      area2 += a.$1 * b.$2 - b.$1 * a.$2;
    }
    final wind = area2 > 0 ? 1.0 : -1.0; // + counter-clockwise
    for (var i = 0; i < outline.length; i++) {
      final j = (i + 1) % outline.length;
      final a = outline[i], b = outline[j];
      // Outward normal: the edge turned a quarter away from the inside.
      final nx = wind * (b.$2 - a.$2), ny = wind * (a.$1 - b.$1);
      if (!facing(normal((nx, ny, 0)))) continue;
      canvas.drawPath(Path()..addPolygon([proj(top[i]), proj(top[j]), proj(bottom[j]), proj(bottom[i])], true), side);
    }
    final topUp = facing(normal((0, 0, 1)));
    final face = topUp ? top : bottom;
    canvas.drawPath(Path()..addPolygon([for (final p in face) proj(p)], true),
        Paint()..color = topUp ? cs.primary : Color.lerp(cs.primary, Colors.black, 0.5)!);

    // Toe cap on the top, and a chevron, so the direction reads at a glance.
    if (topUp) {
      canvas.drawPath(
          Path()..addPolygon([for (var i = 0; i < outline.length; i++) if (outline[i].$1 >= capFrom) proj(top[i])], true),
          Paint()..color = cs.tertiary);
      Offset at(double x, double y) => proj(world((x, y), thick / 2));
      final a = at(0.04, 0.08), b = at(0.19, 0), e = at(0.04, -0.08);
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

  static double _tanh(double x) {
    final e = exp(-2 * x);
    return (1 - e) / (1 + e);
  }

  static double _dot(_V3 a, _V3 b) => a.$1 * b.$1 + a.$2 * b.$2 + a.$3 * b.$3;
  static _V3 _cross(_V3 a, _V3 b) => (a.$2 * b.$3 - a.$3 * b.$2, a.$3 * b.$1 - a.$1 * b.$3, a.$1 * b.$2 - a.$2 * b.$1);

  @override
  bool shouldRepaint(_FootPainter old) => true;
}
