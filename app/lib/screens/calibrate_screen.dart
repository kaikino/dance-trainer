import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../ui/feet_diagram.dart';
import '../ui/style.dart';
import 'live_view_screen.dart';
import 'preset_screen.dart';

/// Guides the dancer through calibrating one or both feet, one foot at a time.
/// The node does the measuring and reports each phase in Status; this screen
/// says what to do now. The buzzes are only a backup for the same cues.
class CalibrateScreen extends StatefulWidget {
  const CalibrateScreen({super.key, required this.manager, required this.nodes, this.returnToRoutine = false});
  final NodeManager manager;
  final List<NodeClient> nodes;

  /// Opened from the routine screen: when done, go back there instead of opening it.
  final bool returnToRoutine;

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

  String _foot(NodeClient n) => footName(n.role).toLowerCase();

  /// The result in plain words, from the spread of the slides (the node
  /// rejects anything over 15°).
  static String _friendly(int spreadDeg) => switch (spreadDeg) {
        <= 6 => 'Great, steady slides',
        <= 10 => 'Good, fairly steady slides',
        _ => 'Done, though the slides wandered a little. Calibrate again if steps are judged the wrong way.',
      };

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
    if (!n.connected) {
      _fail('The ${_foot(n)} node is not connected. Go back, scan for it, and try again.');
      return;
    }
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
        bottomNavigationBar:
            BottomActions(stackOnPhone: true, children: _finished ? _summaryActions(context) : _stepActions()),
        body: ContentWidth(
          child: FillScrollView(
            padding: EdgeInsets.all(Space.gutter(context)),
            child: AnimatedSwitcher(
              duration: Motion.fade,
              child: KeyedSubtree(
                key: ValueKey((_finished, _error != null)),
                child: _finished ? _summary(context) : _step(context, _node!),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _step(BuildContext context, NodeClient n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final st = n.status;
    final phase = _seenRunning ? st?.calPhase : CalPhase.still;
    final slide = (st?.calSlides ?? 0).clamp(0, _slides - 1) + 1;
    final foot = _foot(n);
    final still = phase != CalPhase.slide && phase != CalPhase.back;
    final (title, detail) = switch (phase) {
      CalPhase.slide => (
          'Slide your $foot foot forward',
          'About 30 cm along the floor, straight ahead. Slide $slide of $_slides.'
        ),
      CalPhase.back => ('Bring your $foot foot back', 'To where it started, then hold still.'),
      _ => ('Stand still', 'It starts by itself once you are steady.'),
    };
    final failed = _error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${widget.nodes.length > 1 ? 'Foot ${_index + 1} of ${widget.nodes.length}. ' : ''}'
          'Calibrating the $foot foot, so the app knows which way is forward.',
          style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const Spacer(),
        const SizedBox(height: Space.md),
        if (failed)
          Icon(Icons.error_rounded, size: 72, color: scheme.error)
        else
          FeetDiagram(
            active: n.role,
            arrow: switch (phase) {
              CalPhase.slide => FeetArrow.forward,
              CalPhase.back => FeetArrow.back,
              _ => FeetArrow.none,
            },
            showStance: still,
            height: 240,
          ),
        const SizedBox(height: Space.lg),
        Text(failed ? 'That did not work' : title, textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
        const SizedBox(height: Space.sm),
        Text(failed ? _error! : detail, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        // The stance the step classifier assumes: big, while it is being
        // measured. Its slot is kept while sliding so nothing above it jumps.
        if (!failed) ...[
          const SizedBox(height: Space.lg),
          AnimatedOpacity(opacity: still ? 1 : 0, duration: Motion.fade, child: _StanceCard()),
        ],
        if (!failed) ...[
          const SizedBox(height: Space.xl),
          _Progress(phase: phase, slides: st?.calSlides ?? 0, total: _slides),
        ],
        const Spacer(),
      ],
    );
  }

  List<Widget> _stepActions() {
    final failed = _error != null;
    return [
      if (failed)
        FilledButton.icon(onPressed: _start, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
      if (failed && widget.nodes.length > 1) OutlinedButton(onPressed: _skip, child: const Text('Skip this foot')),
      OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
    ];
  }

  List<Widget> _summaryActions(BuildContext context) => [
        FilledButton.icon(
          onPressed: widget.returnToRoutine
              ? () => Navigator.pop(context)
              : () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => PresetScreen(manager: widget.manager)),
                  ),
          icon: const Icon(Icons.queue_music_rounded),
          label: Text(widget.returnToRoutine ? 'Back to the routine' : 'Choose a routine',
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => LiveViewScreen(manager: widget.manager)),
          ),
          icon: const Icon(Icons.threed_rotation_rounded),
          label: const Text('Live view', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ];

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Icon(Icons.check_circle_rounded,
            size: 72, color: _skipped.isEmpty ? StatusColors.ok(context) : StatusColors.warn(context)),
        const SizedBox(height: Space.lg),
        Text(_skipped.isEmpty ? 'Calibrated' : 'Partly calibrated',
            textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
        const SizedBox(height: Space.sm),
        for (final e in _done.entries)
          Text('${footName(e.key.role)} foot: ${_friendly(e.value)}',
              textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        for (final n in _skipped)
          Text('${footName(n.role)} foot: not calibrated',
              textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        const Spacer(),
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
    // Plain status pills, not chips: nothing here is tappable.
    Widget mark(String label, bool done, bool now) => Semantics(
          label: '$label, ${done ? 'done' : now ? 'now' : 'to do'}',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.xs),
            child: StatusPill(
              icon: done
                  ? Icons.check_circle_rounded
                  : (now ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
              text: label,
              color: done ? StatusColors.ok(context) : (now ? scheme.primary : null),
            ),
          ),
        );
    final still = phase == CalPhase.still;
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        mark('Still', !still, still),
        for (var i = 0; i < total; i++) mark('Slide ${i + 1}', slides > i, phase == CalPhase.slide && slides == i),
      ],
    );
  }
}

/// The calibration stance, set apart so it is read: the classifier assumes it.
class _StanceCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: Radii.mdAll),
      child: Row(
        children: [
          Icon(Icons.accessibility_new_rounded, color: scheme.onTertiaryContainer, size: 32),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(stanceInstruction,
                style: theme.textTheme.titleMedium?.copyWith(color: scheme.onTertiaryContainer, height: 1.35)),
          ),
        ],
      ),
    );
  }
}
