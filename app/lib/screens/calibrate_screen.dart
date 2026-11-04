import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import 'live_view_screen.dart';

/// Guides the dancer through calibrating one or both feet, one foot at a time.
/// The node does the measuring and reports each phase in Status; this screen
/// says what to do now. The buzzes are only a backup for the same cues.
class CalibrateScreen extends StatefulWidget {
  const CalibrateScreen({super.key, required this.manager, required this.nodes});
  final NodeManager manager;
  final List<NodeClient> nodes;

  @override
  State<CalibrateScreen> createState() => _CalibrateScreenState();
}

class _CalibrateScreenState extends State<CalibrateScreen> {
  static const _slides = 3;
  static const _startTimeout = Duration(seconds: 6);
  static const _runTimeout = Duration(seconds: 90);

  int _index = 0;
  bool _running = false;
  bool _seenRunning = false;
  String? _error; // why the current foot failed
  final _done = <NodeClient, int>{}; // foot → spread in degrees
  final _skipped = <NodeClient>{};
  Timer? _watchdog;

  NodeClient? get _node => _index < widget.nodes.length ? widget.nodes[_index] : null;
  bool get _finished => _node == null;

  String _foot(NodeClient n) => n.role == Role.left ? 'left' : 'right';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final n = _node;
    if (n == null) return;
    setState(() {
      _error = null;
      _running = true;
      _seenRunning = false;
    });
    if (n.status?.calPhase == null) {
      _fail('The ${_foot(n)} node has old firmware that cannot be guided. Reflash it with the current firmware.');
      return;
    }
    n.addListener(_onNode);
    // Armed first: the node's first progress report can beat the write's reply.
    _arm(_startTimeout, 'The ${_foot(n)} node did not respond. Check that it is on and connected.');
    try {
      await n.calibrate();
    } catch (e) {
      _fail('Could not start: $e');
    }
  }

  void _arm(Duration d, String message) {
    _watchdog?.cancel();
    _watchdog = Timer(d, () {
      final n = _node;
      _fail(message);
      if (n != null && n.connected) unawaited(n.cancelCalibration().catchError((_) {}));
    });
  }

  void _onNode() {
    final n = _node;
    if (n == null || !_running || !mounted) return;
    if (!n.connected) {
      _fail('Lost the connection to the ${_foot(n)} node.');
      return;
    }
    final phase = n.status?.calPhase;
    switch (phase) {
      case CalPhase.still || CalPhase.slide || CalPhase.back:
        if (!_seenRunning) {
          _seenRunning = true;
          _arm(_runTimeout, 'The ${_foot(n)} node stopped responding.');
        }
      // A result left over from an earlier run does not count until this run has begun.
      case CalPhase.done when _seenRunning:
        _done[n] = n.status!.calSpreadDeg;
        _stopListening(n);
        _running = false;
        _index++;
        if (_finished) {
          _watchdog?.cancel();
        } else {
          unawaited(_start());
        }
      case CalPhase.failStill when _seenRunning:
        _fail('Could not get a steady reading. Stand with your feet flat and keep still until the next '
            'instruction. The previous calibration is unchanged.');
      case CalPhase.failSlide when _seenRunning:
        _fail('Did not see the slide. Slide the foot about 30 cm along the floor at a normal speed, when the '
            'screen says so. This foot has tilt only until this works.');
      case CalPhase.failSpread when _seenRunning:
        _fail('The slides went in different directions (up to ${n.status!.calSpreadDeg}° off). Slide straight '
            'ahead each time and bring the foot back between slides. This foot has tilt only until this works.');
      default:
        break;
    }
    if (mounted) setState(() {});
  }

  void _stopListening(NodeClient n) {
    n.removeListener(_onNode);
    _watchdog?.cancel();
  }

  void _fail(String message) {
    final n = _node;
    if (n != null) _stopListening(n);
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = message;
    });
  }

  void _skip() {
    _skipped.add(_node!);
    _index++;
    _error = null;
    if (_finished) {
      setState(() {});
    } else {
      unawaited(_start());
    }
  }

  Future<void> _cancel() async {
    final n = _node;
    if (n != null && _running) {
      _stopListening(n);
      _running = false;
      try {
        await n.cancelCalibration();
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    for (final n in widget.nodes) {
      n.removeListener(_onNode);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Calibrate')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: _finished ? _summary(context) : _step(context, _node!),
        ),
      ),
    );
  }

  Widget _step(BuildContext context, NodeClient n) {
    final theme = Theme.of(context);
    final st = n.status;
    final phase = _seenRunning ? st?.calPhase : CalPhase.still;
    final slide = (st?.calSlides ?? 0).clamp(0, _slides - 1) + 1;
    final foot = _foot(n).toUpperCase();
    final (icon, title, detail) = switch (phase) {
      CalPhase.slide => (
          Icons.arrow_upward,
          'Slide your $foot foot forward',
          'About 30 cm along the floor, straight ahead. Slide $slide of $_slides.'
        ),
      CalPhase.back => (Icons.arrow_downward, 'Bring your $foot foot back', 'Then hold still.'),
      _ => (
          Icons.accessibility_new,
          'Stand still',
          'Feet flat, toes pointing forward. It starts by itself once you are steady.'
        ),
    };
    final failed = _error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.nodes.length > 1)
          Text('Foot ${_index + 1} of ${widget.nodes.length}', style: theme.textTheme.titleSmall),
        const Spacer(),
        Icon(failed ? Icons.error_outline : icon, size: 72, color: failed ? theme.colorScheme.error : theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(failed ? 'That did not work' : title,
            textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(failed ? _error! : detail, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        if (!failed) ...[
          const SizedBox(height: 24),
          _Progress(phase: phase, slides: st?.calSlides ?? 0, total: _slides),
        ],
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (failed && widget.nodes.length > 1) TextButton(onPressed: _skip, child: const Text('Skip this foot')),
            TextButton(onPressed: _cancel, child: const Text('Cancel')),
            if (failed) ...[
              const SizedBox(width: 8),
              FilledButton(onPressed: _start, child: const Text('Try again')),
            ],
          ],
        ),
      ],
    );
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Icon(Icons.check_circle_outline, size: 72, color: _skipped.isEmpty ? Colors.green : Colors.orange),
        const SizedBox(height: 16),
        Text(_skipped.isEmpty ? 'Calibrated' : 'Partly calibrated',
            textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        for (final e in _done.entries)
          Text('${e.key.role == Role.left ? 'Left' : 'Right'} foot: slides agreed within ${e.value}°',
              textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        for (final n in _skipped)
          Text('${n.role == Role.left ? 'Left' : 'Right'} foot: not calibrated', textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => LiveViewScreen(manager: widget.manager)),
              ),
              icon: const Icon(Icons.threed_rotation),
              label: const Text('Check it in Live view'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Hold still, then one mark per slide.
class _Progress extends StatelessWidget {
  const _Progress({required this.phase, required this.slides, required this.total});
  final CalPhase? phase;
  final int slides, total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget mark(String label, bool done, bool now) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Chip(
            label: Text(label),
            avatar: done ? const Icon(Icons.check, size: 18) : null,
            backgroundColor: now ? scheme.primaryContainer : null,
          ),
        );
    final still = phase == CalPhase.still;
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        mark('Still', !still, still),
        for (var i = 0; i < total; i++)
          mark('Slide ${i + 1}', slides > i, phase == CalPhase.slide && slides == i),
      ],
    );
  }
}
