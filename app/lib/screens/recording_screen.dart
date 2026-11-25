import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import '../chart/floor_map.dart' show floorColor;
import '../store/recording.dart';
import '../ui/style.dart';
import '../store/app_dirs.dart';
import '../ui/share.dart';

/// The raw data of one recorded run: acceleration, rotation and tilt per foot
/// against time, with the beats and every step the node reported, so a
/// recording can be checked before it is used for training. Pops true if the
/// run was deleted.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.dir, this.canDelete = true});
  final Directory dir;
  final bool canDelete;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

enum _Feet { left, right, both }

enum _Plot {
  acc('Acceleration', 'g'),
  mag('|a|', 'g'),
  gyro('Rotation', 'dps'),
  tilt('Tilt', '°');

  const _Plot(this.title, this.unit);
  final String title, unit;
}

const _xyz = [Color(0xFFE5484D), Color(0xFF30A46C), Color(0xFF3E63DD)];

class _RecordingScreenState extends State<RecordingScreen> {
  Recording? _rec;
  Object? _error;
  _Feet _feet = _Feet.both;
  final _plots = {_Plot.acc, _Plot.gyro, _Plot.tilt};
  final _view = ValueNotifier<(double, double)>((0, 10));

  /// Left above right instead of side by side, once chosen; remembered while
  /// the app runs. Unset: side by side, except on a phone held upright.
  static bool? _stackedPref;
  final _cursor = ValueNotifier<double?>(null);

  @override
  void initState() {
    super.initState();
    Recording.load(widget.dir).then((r) {
      if (!mounted) return;
      setState(() => _rec = r);
      _view.value = (0, min(10.0, max(1.0, r.duration)));
      if (r.feet.length == 1) _feet = r.feet.containsKey(Role.left) ? _Feet.left : _Feet.right;
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    _view.dispose();
    _cursor.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final yes = await confirmDelete(context, 'Delete this run?', 'Its recording is removed from ${AppDirs.deviceName(MediaQuery.sizeOf(context))}.');
    if (!yes) return;
    await widget.dir.delete(recursive: true);
    if (mounted) Navigator.pop(context, true);
  }

  void _jumpTo(double t) {
    final (a, b) = _view.value;
    final w = b - a;
    _view.value = _clampView(t - w / 2, t + w / 2);
    _cursor.value = t;
  }

  (double, double) _clampView(double a, double b) {
    final double d = max(_rec?.duration ?? 1.0, 0.5);
    final double w = (b - a).clamp(0.5, d + 0.5);
    final double s = a.clamp(-0.25, max(-0.25, d + 0.25 - w));
    return (s, s + w);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _rec;
    return Scaffold(
      appBar: AppBar(
        title: Text(r == null ? 'Recording' : r.presetName),
        actions: [
          if (r != null)
            IconButton(
              onPressed: () => shareFiles(context, r.dir.listSync().whereType<File>().toList(),
                  subject: 'Dance Trainer recording ${r.id}'),
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: 'Share the files',
            ),
          if (widget.canDelete)
            IconButton(
              onPressed: _delete,
              icon: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
              tooltip: 'Delete this run',
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not read this recording: $_error'))
          : r == null
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(top: false, child: _body(context, r)),
    );
  }

  Widget _body(BuildContext context, Recording r) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    // A phone (either way up): the page scrolls through charts of a fixed,
    // readable height. A tablet: every chart fits the screen.
    final compact = size.width < 700 || size.height < 560;
    final stacked = _stackedPref ?? (compact && size.width < size.height);
    final feet = switch (_feet) {
      _Feet.left => [Role.left],
      _Feet.right => [Role.right],
      _Feet.both => [Role.left, Role.right],
    }.where(r.feet.containsKey).toList();
    final plots = [
      for (final p in _Plot.values)
        if (_plots.contains(p) && (p != _Plot.gyro || feet.any((f) => r.feet[f]!.gyr != null))) p
    ];
    final controls = _controls(context, r, stacked, compact: compact);
    final Widget charts;
    if (feet.isEmpty) {
      charts = Center(child: Text('No sensor data in this run.', style: theme.textTheme.titleMedium));
    } else if (compact) {
      final h = size.height < 500 ? 150.0 : 175.0;
      charts = ListView(
        padding: const EdgeInsets.only(bottom: Space.sm),
        children: [
          if (stacked)
            for (final f in feet) ...[
              _footHeader(context, f),
              for (final p in plots)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.xs),
                  child: SizedBox(height: h, child: _chart(r, f, p, showTime: true)),
                ),
              const SizedBox(height: Space.sm),
            ]
          else ...[
            Row(children: [
              for (final f in feet) Expanded(child: _footHeader(context, f)),
            ]),
            for (final p in plots)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: SizedBox(
                  height: h,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var i = 0; i < feet.length; i++) ...[
                      if (i > 0) const SizedBox(width: Space.sm),
                      Expanded(child: _chart(r, feet[i], p, showTime: true)),
                    ],
                  ]),
                ),
              ),
          ],
        ],
      );
    } else {
      charts = Flex(
        // Left beside right (each foot a column of charts), or left above
        // right (each foot a row of charts).
        direction: stacked ? Axis.vertical : Axis.horizontal,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < feet.length; i++) ...[
            if (i > 0) const SizedBox(width: Space.md, height: Space.sm),
            Expanded(child: _column(context, r, feet[i], plots, across: stacked)),
          ],
        ],
      );
    }
    Widget scrollRow(List<Widget> children) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: Space.sm),
              children[i],
            ],
          ]),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? Space.md : Space.lg, 0, compact ? Space.md : Space.lg, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          compact ? scrollRow(_factChips(context, r)) : Wrap(spacing: Space.sm, runSpacing: Space.xs, children: _factChips(context, r)),
          const SizedBox(height: Space.sm),
          compact
              ? scrollRow(controls)
              : Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: controls,
                ),
          const SizedBox(height: Space.sm),
          Expanded(child: charts),
          const SizedBox(height: Space.sm),
          SizedBox(height: compact ? 36 : 44, child: _Overview(rec: r, view: _view, clamp: _clampView)),
          if (!compact) ...[
            const SizedBox(height: Space.xs),
            Text('Drag to move, pinch to zoom, tap for values. Thin lines are beats; coloured lines are the steps the node felt.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  List<Widget> _controls(BuildContext context, Recording r, bool stacked, {required bool compact}) {
    final faint = Theme.of(context).colorScheme.onSurfaceVariant;
    return [
      SegmentedButton<_Feet>(
        segments: const [
          ButtonSegment(value: _Feet.left, label: Text('Left')),
          ButtonSegment(value: _Feet.right, label: Text('Right')),
          ButtonSegment(value: _Feet.both, label: Text('Both')),
        ],
        selected: {_feet},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() => _feet = s.first),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.view_column_rounded, size: 20, color: faint),
          Switch(value: stacked, onChanged: (v) => setState(() => _stackedPref = v)),
          Icon(Icons.view_agenda_rounded, size: 20, color: faint),
          const SizedBox(width: Space.xs),
          GestureDetector(
            onTap: () => setState(() => _stackedPref = !stacked),
            child: Text('Left above right', style: Theme.of(context).textTheme.labelLarge),
          ),
        ],
      ),
      for (final p in _Plot.values)
        FilterChip(
          label: Text(p.title),
          selected: _plots.contains(p),
          onSelected: (on) => setState(() => on ? _plots.add(p) : (_plots.length > 1 ? _plots.remove(p) : null)),
        ),
      OutlinedButton.icon(
        onPressed: r.strikes.isEmpty ? null : () => _stepList(context, r),
        icon: const Icon(Icons.format_list_bulleted_rounded),
        label: Text('Steps (${r.strikes.length})'),
      ),
      TextButton.icon(
        onPressed: () => _view.value = _clampView(0, r.duration),
        icon: const Icon(Icons.zoom_out_map_rounded),
        label: const Text('Whole run'),
      ),
    ];
  }

  Widget _footHeader(BuildContext context, Role f) => Padding(
        padding: const EdgeInsets.only(bottom: Space.xs),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: floorColor(f), shape: BoxShape.circle)),
          const SizedBox(width: Space.xs),
          Text('${footName(f)} ankle',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ]),
      );

  /// One chart; drag, pinch and tap move the view every chart shares.
  Widget _chart(Recording r, Role f, _Plot p, {required bool showTime}) => LayoutBuilder(
        builder: (context, c) => _Gestures(
          width: c.maxWidth - _ChartPainter.left - _ChartPainter.right,
          view: _view,
          cursor: _cursor,
          clamp: _clampView,
          child: _Chart(
            series: r.feet[f]!,
            plot: p,
            foot: f,
            capture: r.capture,
            strikes: [for (final m in r.strikes) if (m.foot == f) m],
            beats: r.beats,
            view: _view,
            cursor: _cursor,
            showTime: showTime,
          ),
        ),
      );

  List<Widget> _factChips(BuildContext context, Recording r) {
    final theme = Theme.of(context);
    final when = RecordingIndex.parseStamp(r.id);
    String foot(Role f) {
      final s = r.feet[f];
      if (s == null) return '${footName(f)}: no data';
      return '${footName(f)}: ${s.rateHz.toStringAsFixed(0)} Hz'
          '${s.gaps == 0 ? '' : ' · ${s.gaps} gap${s.gaps == 1 ? '' : 's'}'}';
    }

    final mismatched = r.capture ? r.strikes.where((s) => s.label >= 0 && s.label != s.cls.index).length : 0;
    final chips = [
      if (when != null) RecordingIndex.formatWhen(when),
      if (r.dancer.isNotEmpty) r.dancer,
      r.capture ? 'Recording' : (r.mode.isEmpty ? 'Run' : r.mode),
      '${r.duration.toStringAsFixed(1)} s',
      '${r.strikes.length} steps',
      if (r.capture && r.strikes.isNotEmpty) '$mismatched called differently from the label',
      foot(Role.left),
      foot(Role.right),
    ];
    return [
      for (final c in chips)
        Chip(
          label: Text(c),
          visualDensity: VisualDensity.compact,
          labelStyle: theme.textTheme.labelLarge,
          side: BorderSide.none,
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
        ),
    ];
  }

  /// One foot's charts (tablet): down a column (side by side layout) or along
  /// a row ([across]: left above right), filling the space.
  Widget _column(BuildContext context, Recording r, Role f, List<_Plot> plots, {bool across = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _footHeader(context, f),
          Expanded(
            child: across
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < plots.length; i++) ...[
                        if (i > 0) const SizedBox(width: Space.xs),
                        Expanded(child: _chart(r, f, plots[i], showTime: true)),
                      ],
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final p in plots)
                        Expanded(
                            child: Padding(
                                padding: const EdgeInsets.only(bottom: Space.xs),
                                child: _chart(r, f, p, showTime: p == plots.last))),
                    ],
                  ),
          ),
        ],
      );

  void _stepList(BuildContext context, Recording r) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, sc) => ListView.builder(
          controller: sc,
          itemCount: r.strikes.length,
          itemBuilder: (context, i) {
            final m = r.strikes[i];
            final label = m.label >= 0 && m.label < StepClass.values.length ? StepClass.values[m.label] : null;
            final odd = r.capture && label != null && label != m.cls;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: floorColor(m.foot),
                child: Icon(stepIcon(m.cls, m.foot) ?? Icons.circle_outlined, color: Colors.white),
              ),
              title: Text('${footName(m.foot)}: ${stepLabel(m.cls, m.foot)}'
                  '${r.capture ? (label == null ? '  ·  label: unusable' : '  ·  label: ${stepLabel(label, m.foot)}') : '  ·  ${m.verdict.name}'}'),
              subtitle: Text('${m.t.toStringAsFixed(2)} s · confidence ${m.conf}'),
              trailing: odd ? Icon(Icons.error_outline_rounded, color: theme.colorScheme.error) : null,
              onTap: () {
                Navigator.pop(context);
                _jumpTo(m.t);
              },
            );
          },
        ),
      ),
    );
  }
}

/// Asks before deleting; true to go ahead.
Future<bool> confirmDelete(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ==
    true;

/// Pan (drag), zoom (pinch) and the cursor (tap) for a column of charts.
class _Gestures extends StatefulWidget {
  const _Gestures(
      {required this.width, required this.view, required this.cursor, required this.clamp, required this.child});
  final double width;
  final ValueNotifier<(double, double)> view;
  final ValueNotifier<double?> cursor;
  final (double, double) Function(double, double) clamp;
  final Widget child;

  @override
  State<_Gestures> createState() => _GesturesState();
}

class _GesturesState extends State<_Gestures> {
  (double, double)? _start;
  double _focusT = 0;

  double _tAt(double x) {
    final (a, b) = widget.view.value;
    return a + (x - _ChartPainter.left) / max(1, widget.width) * (b - a);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => widget.cursor.value = _tAt(d.localPosition.dx),
        onScaleStart: (d) {
          _start = widget.view.value;
          _focusT = _tAt(d.localFocalPoint.dx);
        },
        onScaleUpdate: (d) {
          final s = _start;
          if (s == null) return;
          final w0 = s.$2 - s.$1;
          final w = w0 / d.horizontalScale.clamp(0.05, 20);
          // Keep the time under the fingers under the fingers.
          final frac = (d.localFocalPoint.dx - _ChartPainter.left) / max(1, widget.width);
          final a = _focusT - frac * w;
          widget.view.value = widget.clamp(a, a + w);
        },
        child: widget.child,
      );
}

/// One plot of one foot.
class _Chart extends StatelessWidget {
  const _Chart({
    required this.series,
    required this.plot,
    required this.foot,
    required this.capture,
    required this.strikes,
    required this.beats,
    required this.view,
    required this.cursor,
    required this.showTime,
  });
  final FootSeries series;
  final _Plot plot;
  final Role foot;
  final bool capture;
  final List<StrikeMark> strikes;
  final List<double> beats;
  final ValueNotifier<(double, double)> view;
  final ValueNotifier<double?> cursor;
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final traces = switch (plot) {
      _Plot.acc => [
          for (var k = 0; k < 3; k++) _Trace(['x', 'y', 'z'][k], _xyz[k], series.acc[k]),
        ],
      _Plot.mag => [_Trace('|a|', floorColor(foot), series.accMag)],
      _Plot.gyro => [
          if (series.gyr case final g?)
            for (var k = 0; k < 3; k++) _Trace(['x', 'y', 'z'][k], _xyz[k], g[k]),
        ],
      _Plot.tilt => [
          _Trace('pitch', const Color(0xFFE5484D), series.pitch),
          _Trace('roll', const Color(0xFF3E63DD), series.roll),
        ],
    };
    final title = switch (plot) {
      _Plot.acc => capture ? 'Acceleration (sensor frame, with gravity)' : 'Acceleration (foot frame)',
      _ => plot.title,
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: Radii.mdAll),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ChartPainter(
            t: series.t,
            traces: traces,
            title: title,
            unit: plot.unit,
            strikes: strikes,
            beats: beats,
            view: view,
            cursor: cursor,
            showTime: showTime,
            capture: capture,
            ink: scheme.onSurface,
            faint: scheme.onSurfaceVariant,
            grid: scheme.outlineVariant,
            surface: scheme.surfaceContainerHighest,
          ),
        ),
      ),
    );
  }
}

class _Trace {
  const _Trace(this.name, this.color, this.v);
  final String name;
  final Color color;
  final Float32List v;
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.t,
    required this.traces,
    required this.title,
    required this.unit,
    required this.strikes,
    required this.beats,
    required this.view,
    required this.cursor,
    required this.showTime,
    required this.capture,
    required this.ink,
    required this.faint,
    required this.grid,
    required this.surface,
  }) : super(repaint: Listenable.merge([view, cursor]));

  final Float64List t;
  final List<_Trace> traces;
  final String title, unit;
  final List<StrikeMark> strikes;
  final List<double> beats;
  final ValueNotifier<(double, double)> view;
  final ValueNotifier<double?> cursor;
  final bool showTime, capture;
  final Color ink, faint, grid, surface;

  static const left = 46.0, right = 10.0, top = 22.0;
  double get bottom => showTime ? 18.0 : 6.0;

  int _lower(double x) {
    var lo = 0, hi = t.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (t[m] < x) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    return lo;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final (a, b) = view.value;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    double xOf(double s) => plot.left + (s - a) / (b - a) * plot.width;

    final i0 = max(0, _lower(a) - 1), i1 = min(t.length, _lower(b) + 1);
    // Y range from what is visible, padded; a floor so noise is not blown up.
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final tr in traces) {
      for (var i = i0; i < i1; i++) {
        final v = tr.v[i];
        if (v.isNaN) continue;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (!lo.isFinite) {
      lo = -1;
      hi = 1;
    }
    final minSpan = switch (unit) { 'g' => 0.3, 'dps' => 40.0, _ => 10.0 };
    if (hi - lo < minSpan) {
      final c = (hi + lo) / 2;
      lo = c - minSpan / 2;
      hi = c + minSpan / 2;
    }
    final pad = (hi - lo) * 0.08;
    lo -= pad;
    hi += pad;
    double yOf(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;

    // Grid: y ticks, then beats.
    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final step = _nice((hi - lo) / 4);
    for (var v = (lo / step).ceil() * step; v <= hi; v += step) {
      final y = yOf(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(canvas, _fmt(v, step), Offset(plot.left - 6, y), faint, 10, align: Alignment.centerRight);
    }
    if (lo < 0 && hi > 0) {
      canvas.drawLine(Offset(plot.left, yOf(0)), Offset(plot.right, yOf(0)), gridPaint..color = grid);
    }
    final beatPaint = Paint()
      ..color = faint.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (final s in beats) {
      if (s < a || s > b) continue;
      canvas.drawLine(Offset(xOf(s), plot.top), Offset(xOf(s), plot.bottom), beatPaint);
    }
    if (showTime) {
      final ts = _nice((b - a) / max(2, plot.width / 90));
      for (var s = (a / ts).ceil() * ts; s <= b; s += ts) {
        _text(canvas, '${_fmt(s, ts)} s', Offset(xOf(s), plot.bottom + 9), faint, 10);
      }
    }

    // Steps the node felt: a line, and the call at the top (amber where the
    // training label disagrees).
    canvas.save();
    canvas.clipRect(plot.inflate(1));
    for (final m in strikes) {
      if (m.t < a || m.t > b) continue;
      final x = xOf(m.t);
      final label = m.label >= 0 && m.label < StepClass.values.length ? StepClass.values[m.label] : null;
      final odd = capture ? (label != null && label != m.cls) : (m.verdict != Verdict.correct && m.verdict != Verdict.unjudged);
      final c = odd ? const Color(0xFFE5A000) : floorColor(m.foot);
      canvas.drawLine(
          Offset(x, plot.top),
          Offset(x, plot.bottom),
          Paint()
            ..color = c.withValues(alpha: 0.7)
            ..strokeWidth = 1.5);
    }

    // Traces: a min/max envelope per pixel where samples are denser than pixels.
    for (final tr in traces) {
      final p = Paint()
        ..color = tr.color
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      // A solid line; where samples outnumber pixels, each pixel column keeps
      // its lowest and highest sample (in time order) so peaks are not lost.
      final path = Path();
      var started = false, col = -1 << 30;
      var cMin = 0.0, cMax = 0.0, iMin = 0, iMax = 0;
      void point(double x, double v) {
        if (!started) {
          path.moveTo(x, yOf(v));
          started = true;
        } else {
          path.lineTo(x, yOf(v));
        }
      }

      void flush() {
        if (col == -1 << 30) return;
        final x = plot.left + col + 0.5;
        if (iMin <= iMax) {
          point(x, cMin);
          if (iMax != iMin) point(x, cMax);
        } else {
          point(x, cMax);
          point(x, cMin);
        }
      }

      for (var i = i0; i < i1; i++) {
        final v = tr.v[i];
        if (v.isNaN || (i > i0 && t[i] - t[i - 1] > 0.05)) {
          flush(); // a dropout: no line across it
          col = -1 << 30;
          started = false;
          if (v.isNaN) continue;
        }
        final c = (xOf(t[i]) - plot.left).floor();
        if (c != col) {
          flush();
          col = c;
          cMin = cMax = v;
          iMin = iMax = i;
        } else {
          if (v < cMin) {
            cMin = v;
            iMin = i;
          }
          if (v > cMax) {
            cMax = v;
            iMax = i;
          }
        }
      }
      flush();
      canvas.drawPath(path, p);
    }
    // Step names along the top, where there is room (inside the plot).
    var lastX = -1e9;
    for (final m in strikes) {
      if (m.t < a || m.t > b) continue;
      final x = xOf(m.t);
      final name = stepLabel(m.cls, m.foot);
      if (x < lastX + 6) continue;
      lastX = x + _measure(name, 9.5);
      _text(canvas, name, Offset(x + 3, plot.top + 7), ink, 9.5,
          align: Alignment.centerLeft, bg: surface.withValues(alpha: 0.85));
    }

    canvas.restore();

    // Title and legend.
    _text(canvas, title, Offset(plot.left, 11), ink, 11.5, align: Alignment.centerLeft, weight: FontWeight.w700);
    var lx = plot.right;
    for (final tr in traces.reversed) {
      final w = _measure(tr.name, 10.5);
      lx -= w;
      _text(canvas, tr.name, Offset(lx, 11), tr.color, 10.5, align: Alignment.centerLeft, weight: FontWeight.w700);
      lx -= 10;
    }
    _text(canvas, unit, const Offset(4, 11), faint, 10, align: Alignment.centerLeft);

    // Cursor: a line and the values there.
    final c = cursor.value;
    if (c != null && c >= a && c <= b && t.isNotEmpty) {
      final x = xOf(c);
      canvas.drawLine(
          Offset(x, plot.top),
          Offset(x, plot.bottom),
          Paint()
            ..color = ink.withValues(alpha: 0.6)
            ..strokeWidth = 1);
      final i = _lower(c).clamp(0, t.length - 1);
      final lines = [
        '${t[i].toStringAsFixed(2)} s',
        for (final tr in traces) '${tr.name} ${tr.v[i].toStringAsFixed(unit == 'g' ? 2 : 0)}',
      ];
      final text = lines.join('   ');
      final w = _measure(text, 10.5) + 12;
      final bx = (x + 8 + w > plot.right) ? x - 8 - w : x + 8;
      final box = RRect.fromRectAndRadius(Rect.fromLTWH(bx, plot.bottom - 24, w, 20), const Radius.circular(6));
      canvas.drawRRect(box, Paint()..color = surface);
      _text(canvas, text, Offset(bx + 6, plot.bottom - 14), ink, 10.5, align: Alignment.centerLeft);
    }
  }

  static double _nice(double raw) {
    if (raw <= 0 || !raw.isFinite) return 1;
    final e = pow(10, (log(raw) / ln10).floor()).toDouble();
    final f = raw / e;
    return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * e;
  }

  static String _fmt(double v, double step) => step >= 1 ? v.round().toString() : v.toStringAsFixed(step >= 0.1 ? 1 : 2);

  static final _cache = <(String, double, int, int), TextPainter>{};
  static TextPainter _tp(String s, double size, Color c, FontWeight w) {
    if (_cache.length > 400) _cache.clear();
    return _cache[(s, size, c.toARGB32(), w.value)] ??= TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontFamily: AppType.family, fontSize: size, color: c, fontWeight: w, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  static double _measure(String s, double size) => _tp(s, size, const Color(0xFF000000), FontWeight.w700).width;

  static void _text(Canvas canvas, String s, Offset at, Color c, double size,
      {Alignment align = Alignment.center, FontWeight weight = FontWeight.w500, Color? bg}) {
    final tp = _tp(s, size, c, weight);
    final o = at - Offset((align.x + 1) / 2 * tp.width, tp.height / 2);
    if (bg != null) {
      canvas.drawRRect(RRect.fromRectAndRadius((o & tp.size).inflate(2.5), const Radius.circular(4)), Paint()..color = bg);
    }
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.t != t || old.traces != traces || old.showTime != showTime || old.ink != ink || old.strikes != strikes;
}

/// The whole run, small, with the part on screen highlighted: tap or drag to move there.
class _Overview extends StatelessWidget {
  const _Overview({required this.rec, required this.view, required this.clamp});
  final Recording rec;
  final ValueNotifier<(double, double)> view;
  final (double, double) Function(double, double) clamp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      void moveTo(double x) {
        final d = max(rec.duration, 0.5);
        final tt = x / c.maxWidth * d;
        final (a, b) = view.value;
        view.value = clamp(tt - (b - a) / 2, tt + (b - a) / 2);
      }

      return GestureDetector(
        onTapDown: (d) => moveTo(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => moveTo(d.localPosition.dx),
        child: DecoratedBox(
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: Radii.mdAll),
          child: CustomPaint(
            size: Size.infinite,
            painter: _OverviewPainter(rec, view, scheme.primary, scheme.onSurfaceVariant),
          ),
        ),
      );
    });
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter(this.rec, this.view, this.accent, this.faint) : super(repaint: view);
  final Recording rec;
  final ValueNotifier<(double, double)> view;
  final Color accent, faint;

  @override
  void paint(Canvas canvas, Size size) {
    final d = max(rec.duration, 0.5);
    for (final MapEntry(key: f, value: s) in rec.feet.entries) {
      final cols = size.width.floor();
      final mx = List.filled(cols + 1, 0.0);
      for (var i = 0; i < s.length; i++) {
        final c = (s.t[i] / d * cols).floor().clamp(0, cols);
        mx[c] = max(mx[c], (s.accMag[i] - 1).abs());
      }
      final top = mx.reduce(max);
      final p = Paint()
        ..color = floorColor(f).withValues(alpha: 0.7)
        ..strokeWidth = 1;
      for (var c = 0; c <= cols; c++) {
        final h = top <= 0 ? 0.0 : mx[c] / top * (size.height - 8);
        canvas.drawLine(Offset(c.toDouble(), size.height - 4), Offset(c.toDouble(), size.height - 4 - h), p);
      }
    }
    final (a, b) = view.value;
    final r = RRect.fromRectAndRadius(
        Rect.fromLTRB(a / d * size.width, 1, b / d * size.width, size.height - 1), const Radius.circular(6));
    canvas.drawRRect(r, Paint()..color = accent.withValues(alpha: 0.12));
    canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent);
  }

  @override
  bool shouldRepaint(_OverviewPainter old) => old.rec != rec;
}
