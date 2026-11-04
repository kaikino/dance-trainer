import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';

/// Live check of each node's calibration: a top-down footprint that turns with
/// the foot, an arrow for the way it is moving, and toe / edge tilt gauges.
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
                    'Stand with your toes pointing forward and tap Set straight ahead. The shoe '
                    'should copy your foot: lift the toe, roll onto an edge, turn the toe out. '
                    'Slide a foot forward: the arrow on the floor should point the same way.',
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

  /// Toe turned outward, toe raised, outer edge raised: radians.
  double turnOut = 0, toeUp = 0, outerEdgeUp = 0;

  /// Smoothed foot-frame acceleration, g: forward and outward.
  double fwd = 0, out = 0;

  /// Foot frame → display frame, rows of a 3×3 matrix. `view` keeps the turn
  /// relative to straight ahead; `tilt` drops the heading entirely.
  List<List<double>> view = _eye, tilt = _eye;
  static const _eye = [
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
  ];

  /// Current toe heading relative to straight ahead, + = toward the dancer's left.
  double heading = 0;

  bool get left => node.role == Role.left;

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
    final q = (s.qw, s.qx, s.qy, s.qz);
    final toe = _rotate(q, (1, 0, 0));
    final side = _rotate(q, (0, 1, 0)); // +y of the sensor frame = left of the toe, both feet
    final yaw = atan2(toe.$2, toe.$1);
    if (_zeroPending) {
      _refYaw = yaw;
      _zeroPending = false;
    }
    heading = _wrap(yaw - _refYaw); // + = toe turned to the dancer's left
    turnOut = left ? heading : -heading;
    final r = _matrix(q);
    view = _rotZ(-_refYaw, r);
    tilt = _rotZ(-yaw, r);
    toeUp = asin(toe.$3.clamp(-1.0, 1.0));
    final leftEdgeUp = asin(side.$3.clamp(-1.0, 1.0));
    outerEdgeUp = left ? leftEdgeUp : -leftEdgeUp;

    const a = 0.25;
    fwd += a * (s.ax / 1000 - fwd);
    out += a * (s.ay / 1000 - out); // already mirrored on the right node: + = outward
    _seen = true;
    return true;
  }

  bool get seen => _seen;

  static double _wrap(double r) => atan2(sin(r), cos(r));

  /// Rotation matrix of q, the same as q_rotate() in firmware fusion.c.
  static List<List<double>> _matrix((double, double, double, double) q) {
    final (w, x, y, z) = q;
    return [
      [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
      [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
      [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ];
  }

  /// Rotation about world z by `a`, applied after `m`.
  static List<List<double>> _rotZ(double a, List<List<double>> m) {
    final c = cos(a), s = sin(a);
    return [
      [for (var j = 0; j < 3; j++) c * m[0][j] - s * m[1][j]],
      [for (var j = 0; j < 3; j++) s * m[0][j] + c * m[1][j]],
      m[2],
    ];
  }

  /// v rotated by q, the same matrix as q_rotate() in firmware fusion.c.
  static (double, double, double) _rotate((double, double, double, double) q, (double, double, double) v) {
    final (w, x, y, z) = q;
    final (a, b, c) = v;
    return (
      (1 - 2 * (y * y + z * z)) * a + 2 * (x * y - w * z) * b + 2 * (x * z + w * y) * c,
      2 * (x * y + w * z) * a + (1 - 2 * (x * x + z * z)) * b + 2 * (y * z - w * x) * c,
      2 * (x * z - w * y) * a + 2 * (y * z + w * x) * b + (1 - 2 * (x * x + y * y)) * c,
    );
  }
}

class _FootPanel extends StatelessWidget {
  const _FootPanel({required this.foot});
  final _FootState foot;

  static String _deg(double r) => '${(r * 180 / pi).abs().round()}°';

  String get _motion {
    final mag = sqrt(foot.fwd * foot.fwd + foot.out * foot.out);
    if (mag < 0.12) return 'still';
    if (foot.fwd.abs() >= foot.out.abs()) return foot.fwd > 0 ? 'moving forward' : 'moving back';
    return foot.out > 0 ? 'moving outward' : 'moving inward';
  }

  @override
  Widget build(BuildContext context) {
    final st = foot.node.status;
    final theme = Theme.of(context);
    final (badge, color) = switch (st) {
      null || Status(calFlags: null) => ('Calibration unknown (old firmware)', Colors.grey),
      Status(knowsForward: true) => ('Calibrated', Colors.green),
      Status(calibrated: true) => ('Tilt only: slide the foot forward when calibrating', Colors.orange),
      _ => ('Not calibrated: directions follow the board, not the foot', Colors.red),
    };
    final turn = foot.turnOut.abs() < 3 * pi / 180
        ? 'toe straight ahead'
        : 'toe turned ${_deg(foot.turnOut)} ${foot.turnOut > 0 ? 'out' : 'in'}';
    // Camera behind the dancer, raised, a little to the outside of this foot.
    final outside = foot.left ? -1.0 : 1.0;
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
            const SizedBox(height: 4),
            Text(foot.seen ? '$turn · $_motion' : 'Waiting for data…'),
            Expanded(
              child: CustomPaint(
                painter: _ShoePainter(foot, foot.view, theme, azimuth: 18 * outside, elevation: 35, floor: true),
                size: Size.infinite,
              ),
            ),
            SizedBox(
              height: 110,
              child: Row(
                children: [
                  Expanded(
                    child: _SmallView(
                      // From the dancer's right side: toe on the right of the screen.
                      painter: _ShoePainter(foot, foot.tilt, theme, azimuth: 90, elevation: 0),
                      label: 'Side: toe ${foot.toeUp >= 0 ? 'up' : 'down'} ${_deg(foot.toeUp)}',
                    ),
                  ),
                  Expanded(
                    child: _SmallView(
                      // From behind: the dancer's right on the right of the screen.
                      painter: _ShoePainter(foot, foot.tilt, theme, azimuth: 0, elevation: 0),
                      label: 'Behind: outer edge ${foot.outerEdgeUp >= 0 ? 'up' : 'down'} ${_deg(foot.outerEdgeUp)}',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallView extends StatelessWidget {
  const _SmallView({required this.painter, required this.label});
  final CustomPainter painter;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(child: CustomPaint(painter: painter, size: Size.infinite)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

typedef _V3 = (double, double, double);

/// A simple shoe in the foot frame (+x toe, +y the dancer's left, +z up; length
/// 1, origin at the middle of the sole), rotated by `m` and drawn with an
/// orthographic camera. `azimuth` 0 looks forward from behind the dancer, 90
/// looks from the dancer's right side; `elevation` raises the camera.
class _ShoePainter extends CustomPainter {
  _ShoePainter(this.foot, this.m, this.theme, {required double azimuth, required double elevation, this.floor = false})
      : az = azimuth * pi / 180,
        el = elevation * pi / 180;

  final _FootState foot;
  final List<List<double>> m;
  final ThemeData theme;
  final double az, el;
  final bool floor;

  _V3 _rot(_V3 v) => (
        m[0][0] * v.$1 + m[0][1] * v.$2 + m[0][2] * v.$3,
        m[1][0] * v.$1 + m[1][1] * v.$2 + m[1][2] * v.$3,
        m[2][0] * v.$1 + m[2][1] * v.$2 + m[2][2] * v.$3,
      );

  @override
  void paint(Canvas canvas, Size size) {
    // Camera: d = viewing direction, r = screen right, u = screen up.
    final d = (cos(el) * cos(az), cos(el) * sin(az), -sin(el));
    final r = (sin(az), -cos(az), 0.0);
    final u = _cross(r, d);
    final scale = min(size.width * 0.5, size.height * (el == 0 ? 1.1 : 0.8));
    final c = Offset(size.width / 2, size.height * (el == 0 ? 0.62 : 0.55));
    Offset proj(_V3 p) => c + Offset(_dot(p, r), -_dot(p, u)) * scale;
    canvas.clipRect(Offset.zero & size);

    final guide = Paint()
      ..color = theme.dividerColor
      ..strokeWidth = 1;
    if (floor) {
      // Floor grid, fixed in the world, and the straight-ahead line.
      for (var i = -2; i <= 2; i++) {
        final t = i * 0.25;
        canvas.drawLine(proj((t, -0.6, -0.01)), proj((t, 0.6, -0.01)), guide);
        canvas.drawLine(proj((-0.6, t, -0.01)), proj((0.75, t, -0.01)), guide);
      }
      _arrowLine(canvas, proj((0.6, 0, -0.01)), proj((0.85, 0, -0.01)), theme.colorScheme.outline, 2);
    } else {
      canvas.drawLine(Offset(0, c.dy), Offset(size.width, c.dy), guide); // floor, edge-on
    }

    // Faces: sole slab, heel-and-ankle upper, toe marker on top of the sole.
    final inner = foot.left ? -1.0 : 1.0; // big-toe side
    final sole = _outline(inner, 1.0, xMax: 1.0);
    final upper = _outline(inner, 0.82, xMax: 0.05);
    final soleFaces = _slab(sole, 0, 0.09, theme.colorScheme.primary);
    final upperFaces = _slab(upper, 0.09, 0.32, theme.colorScheme.primaryContainer);
    // Toe arrow painted on top of the sole.
    final decal = _Face([(0.44, 0.03 * inner, 0.09), (0.2, 0.03 * inner + 0.085, 0.09), (0.2, 0.03 * inner - 0.085, 0.09)],
        (0, 0, 1), theme.colorScheme.tertiary);

    // Each block is a (near-)convex prism, so its camera-facing faces never
    // overlap and back-face culling is enough within it. Between the blocks:
    // the upper sits on the sole's top, so when that top faces the camera the
    // sole is behind the upper, otherwise in front of it.
    final light = _norm((-0.3, 0.4, 1.0));
    final edge = Paint()
      ..color = theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    void draw(List<_Face> faces, {bool outline = true}) {
      for (final f in faces) {
        final n = _rot(f.normal);
        if (_dot(n, d) >= 0) continue; // facing away
        final path = Path()..addPolygon([for (final p in f.points) proj(_rot(p))], true);
        final shade = 0.55 + 0.45 * max(0.0, _dot(n, light));
        canvas.drawPath(path, Paint()..color = Color.lerp(Colors.black, f.color, shade)!);
        if (outline) canvas.drawPath(path, edge);
      }
    }

    final topVisible = _dot(_rot((0, 0, 1)), d) < 0;
    if (topVisible) {
      draw(soleFaces);
      draw([decal], outline: false);
      draw(upperFaces);
    } else {
      draw(upperFaces);
      draw(soleFaces);
    }

    // Movement arrow on the floor: foot-frame acceleration turned by the heading.
    if (floor) {
      final g = sqrt(foot.fwd * foot.fwd + foot.out * foot.out);
      if (g > 0.06) {
        final outY = foot.left ? 1.0 : -1.0; // outward is +y on the left foot
        final fx = foot.fwd / g, fy = foot.out * outY / g;
        final h = foot.heading;
        final wx = cos(h) * fx - sin(h) * fy, wy = sin(h) * fx + cos(h) * fy;
        final len = min(g * 1.4, 0.7);
        _arrowLine(canvas, proj((0, 0, -0.01)), proj((wx * len, wy * len, -0.01)), theme.colorScheme.tertiary, 6);
      }
    }
  }

  /// Sole-shaped outline in the xy plane, clockwise seen from above, cut off at
  /// x = xMax (straight front edge) for the upper.
  static List<(double, double)> _outline(double inner, double widthScale, {required double xMax}) {
    double w(double x) => widthScale * (0.11 + 0.075 * sin(pi * (x + 0.5) * 0.85));
    double cy(double x) => inner * 0.035 * max(0.0, x + 0.1); // forefoot leans to the big toe
    final xs = [for (var i = 0; i <= 12; i++) -0.5 + i / 12].where((x) => x <= xMax + 1e-9).toList();
    if (xMax < 0.5 && xs.last < xMax) xs.add(xMax);
    final pts = <(double, double)>[];
    for (final x in xs) {
      pts.add((x, cy(x) + w(x)));
    }
    if (xMax >= 0.5) {
      for (var a = 60; a >= -60; a -= 30) {
        final t = a * pi / 180;
        pts.add((0.5 + 0.9 * w(0.5) * cos(t), cy(0.5) + w(0.5) * sin(t)));
      }
    }
    for (final x in xs.reversed) {
      pts.add((x, cy(x) - w(x)));
    }
    for (var a = -120; a >= -240; a -= 30) {
      final t = a * pi / 180;
      pts.add((-0.5 + 0.8 * w(-0.5) * cos(t), cy(-0.5) + w(-0.5) * sin(t)));
    }
    return pts;
  }

  /// Top, bottom and side faces of an outline extruded from z0 to z1.
  static List<_Face> _slab(List<(double, double)> o, double z0, double z1, Color color) {
    final faces = <_Face>[
      _Face([for (final p in o) (p.$1, p.$2, z1)], (0, 0, 1), color),
      _Face([for (final p in o.reversed) (p.$1, p.$2, z0)], (0, 0, -1), color),
    ];
    for (var i = 0; i < o.length; i++) {
      final a = o[i], b = o[(i + 1) % o.length];
      final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
      final l = sqrt(dx * dx + dy * dy);
      if (l < 1e-9) continue;
      // Clockwise outline: outward normal is (-dy, dx).
      faces.add(_Face([(a.$1, a.$2, z0), (b.$1, b.$2, z0), (b.$1, b.$2, z1), (a.$1, a.$2, z1)],
          (-dy / l, dx / l, 0), color));
    }
    return faces;
  }

  static void _arrowLine(Canvas canvas, Offset a, Offset b, Color color, double width) {
    final v = b - a;
    if (v.distance < 1) return;
    final dir = v / v.distance;
    final p = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(a, b, p);
    final back = -dir * (width * 3);
    final perp = Offset(-dir.dy, dir.dx) * (width * 2);
    canvas.drawPath(
      Path()
        ..moveTo(b.dx + dir.dx * width, b.dy + dir.dy * width)
        ..lineTo(b.dx + back.dx + perp.dx, b.dy + back.dy + perp.dy)
        ..lineTo(b.dx + back.dx - perp.dx, b.dy + back.dy - perp.dy)
        ..close(),
      Paint()..color = color,
    );
  }

  static double _dot(_V3 a, _V3 b) => a.$1 * b.$1 + a.$2 * b.$2 + a.$3 * b.$3;
  static _V3 _cross(_V3 a, _V3 b) =>
      (a.$2 * b.$3 - a.$3 * b.$2, a.$3 * b.$1 - a.$1 * b.$3, a.$1 * b.$2 - a.$2 * b.$1);
  static _V3 _norm(_V3 v) {
    final l = sqrt(_dot(v, v));
    return (v.$1 / l, v.$2 / l, v.$3 / l);
  }

  @override
  bool shouldRepaint(_ShoePainter old) => true;
}

class _Face {
  const _Face(this.points, this.normal, this.color);
  final List<_V3> points;
  final _V3 normal;
  final Color color;
}
