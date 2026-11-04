import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/beat_clock.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';
import '../store/settings.dart';

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

  double get _beatMs => 60000 / _bpm;

  Future<void> _start() async {
    _offsets.clear();
    setState(() {
      _running = true;
      _result = null;
    });
    await _clock.prepare();
    await _clock.start();
    _clock.addListener(_onTick);
  }

  void _onTick() {
    if (_running && _clock.finished) _finish();
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
    _clock.removeListener(_onTick);
    await _clock.stop();
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
    _clock.removeListener(_onTick);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
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
            const SizedBox(height: 16),
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
                        style: const TextStyle(fontSize: 20)),
                  ),
                ),
              )
            else
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow),
                label: Text(_result == null ? 'Start' : 'Try again'),
              ),
            if (!_running && _result == null && _offsets.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Not enough taps. Try again.'),
              ),
            const SizedBox(height: 16),
            Text('Sound delay: $_manual ms${_result != null ? ' (measured)' : ''}',
                style: Theme.of(context).textTheme.titleSmall),
            Slider(
              value: _manual.toDouble(),
              min: 0,
              max: 600,
              divisions: 60,
              label: '$_manual ms',
              onChanged: _running ? null : (v) => setState(() => _manual = v.round()),
            ),
            const Text('If steps still reach the line before you hear the beat, raise it; '
                'if after, lower it.',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            if (_running) await _finish();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _running ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
