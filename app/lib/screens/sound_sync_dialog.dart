import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/beat_clock.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';
import '../store/settings.dart';
import '../ui/tokens.dart';

/// Measures how long this device takes to turn "play" into sound: a slow click
/// track plays and the dancer taps along. The median gap between a tap and the
/// click it belongs to is the delay the beat clock shifts the chart and t0 by.
class SoundSyncDialog extends StatefulWidget {
  const SoundSyncDialog({super.key});

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const SoundSyncDialog());

  @override
  State<SoundSyncDialog> createState() => _SoundSyncDialogState();
}

class _SoundSyncDialogState extends State<SoundSyncDialog> {
  // 75 bpm: 800 ms between clicks, so delays up to ~600 ms map to the right click.
  static const _bpm = 75.0;
  static const _skip = 3; // ignore taps on the first clicks while the dancer locks on
  static const _want = 10;

  final _clock = BeatClock(Preset(0, 'Sound sync', _bpm, 0,
      [for (var b = 1; b <= 20; b++) PresetStep(b.toDouble(), Role.left, StepClass.inPlace)]));
  final _offsets = <double>[];
  bool _running = false;
  int? _result;
  int _manual = AppSettings.audioDelayMs;
  Timer? _tick;

  double get _beatMs => _clock.preset.beatMs;
  bool _disposed = false;

  Future<void> _start() async {
    _offsets.clear();
    setState(() {
      _running = true;
      _result = null;
    });
    // Cancel may close the dialog while the click track loads: stop there,
    // before touching the disposed clock or starting a timer.
    try {
      await _clock.prepare();
    } catch (_) {
      if (_disposed || !_running) return; // the player was torn down under the load
      rethrow;
    }
    if (_disposed || !_running) return;
    await _clock.start();
    if (_disposed || !_running) {
      if (!_disposed) await _clock.stop();
      return;
    }
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_running && _clock.finished) _finish();
    });
  }

  void _tap() {
    final a = _clock.anchorWallMs;
    if (!_running || a == null) return;
    final since = DateTime.now().microsecondsSinceEpoch / 1000.0 - a;
    final k = ((since + 150) / _beatMs).floor();
    if (k < _skip) return;
    _offsets.add(since - k * _beatMs);
    setState(() {});
    if (_offsets.length >= _want) _finish();
  }

  Future<void> _finish() async {
    _tick?.cancel();
    _running = false;
    if (!_disposed) await _clock.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      if (_offsets.length >= 5) {
        final s = [..._offsets]..sort();
        _result = s[s.length ~/ 2].round().clamp(0, 600);
        _manual = _result!;
      }
    });
  }

  Future<void> _save() async {
    AppSettings.audioDelayMs = _manual;
    AppSettings.audioDelayMeasured = true;
    await AppSettings.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    _tick?.cancel();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      // Scrolls in phone landscape and at large text sizes.
      scrollable: true,
      title: const Text('Sync sound to the screen'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Every device takes a moment to play sound. Press Start, listen, '
                'and tap the big button exactly on each click. Use the speaker or '
                'headphones you will dance with.'),
            const SizedBox(height: Space.lg),
            if (_running)
              SizedBox(
                width: double.infinity,
                height: 140,
                child: Listener(
                  // Pointer-down, not tap-up: the finger lands on the beat.
                  onPointerDown: (_) => _tap(),
                  child: FilledButton(
                    onPressed: () {},
                    child: Text('Tap on the click  (${_offsets.length}/$_want)',
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                ),
              )
            else
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(_result == null ? 'Start' : 'Try again'),
              ),
            if (!_running && _result == null && _offsets.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: Space.sm),
                child: Text('Not enough taps. Try again.'),
              ),
            const SizedBox(height: Space.lg),
            Text('Sound delay: $_manual ms${_result != null ? ' (measured)' : ''}', style: theme.textTheme.titleSmall),
            MergeSemantics(
              child: Semantics(
                label: 'Sound delay',
                child: Slider(
                  semanticFormatterCallback: (v) => '${v.round()} milliseconds',
                  value: _manual.toDouble(),
                  min: 0,
                  max: 600,
                  divisions: 60,
                  label: '$_manual ms',
                  onChanged: _running ? null : (v) => setState(() => _manual = v.round()),
                ),
              ),
            ),
            Text(
                'If steps still reach the line before you hear the beat, raise it; '
                'if after, lower it.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            if (_running) {
              _running = false;
              _tick?.cancel();
              await _clock.stop();
            }
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _running ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
