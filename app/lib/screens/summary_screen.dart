import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../ble/protocol.dart';
import '../models/preset.dart';
import '../store/session_store.dart';
import 'preset_screen.dart';

/// End-of-session numbers: accuracy, timing, errors by foot and step type, and
/// an export button that shares the session folder's files.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key, required this.preset, required this.recorder, required this.kind});

  final Preset preset;
  final SessionRecorder recorder;
  final SessionKind kind;

  @override
  Widget build(BuildContext context) {
    final evs = recorder.events;
    final judged = evs.where((r) => r.ev.verdict != Verdict.unjudged).toList();
    final correct = judged.where((r) => r.ev.verdict == Verdict.correct).length;
    final acc = judged.isEmpty ? null : correct / judged.length;
    final timed = judged.where((r) => r.ev.verdict == Verdict.correct || r.ev.verdict == Verdict.offBeat);
    final meanErr = timed.isEmpty ? null : timed.map((r) => r.ev.timingErrMs).reduce((a, b) => a + b) / timed.length;

    // Errors by (foot, expected class).
    final errors = <String, int>{};
    for (final r in judged.where((r) => r.ev.verdict != Verdict.correct)) {
      final key = '${r.foot == Role.left ? 'L' : 'R'} ${r.ev.expectedClass.name}';
      errors[key] = (errors[key] ?? 0) + 1;
    }
    final worst = errors.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Scaffold(
      appBar: AppBar(title: const Text('Session summary')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${preset.name}, ${preset.bpm.round()} bpm, ${kind.name}',
              style: Theme.of(context).textTheme.titleMedium),
          Text(recorder.sessionId, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          Row(
            children: [
              _stat(context, acc == null ? '–' : '${(acc * 100).round()}%', 'correct'),
              _stat(context, '${evs.length}', kind == SessionKind.capture ? 'steps recorded' : 'steps'),
              _stat(context, meanErr == null ? '–' : '${meanErr >= 0 ? '+' : ''}${meanErr.round()}', 'ms late, avg'),
            ],
          ),
          const SizedBox(height: 24),
          if (kind == SessionKind.capture) ...[
            const Text('Capture session. Labels were assigned from the schedule; '
                'export the folder and run ml/label.py to check them.'),
          ] else ...[
            Text('Errors by foot and step', style: Theme.of(context).textTheme.titleSmall),
            if (worst.isEmpty) const Text('No errors.') else
              for (final e in worst)
                ListTile(dense: true, title: Text(e.key), trailing: Text('${e.value}')),
            if (worst.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('What to drill: ${worst.first.key.replaceFirst('L ', 'left foot ').replaceFirst('R ', 'right foot ')}.',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
          ],
          const SizedBox(height: 24),
          Text('Saved to ${recorder.dir.path}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Share.shareXFiles(
              [for (final f in recorder.files) XFile(f.path)],
              subject: 'Dance Trainer session ${recorder.sessionId}',
            ),
            icon: const Icon(Icons.ios_share),
            label: const Text('Export session files'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String big, String small) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                Text(big, style: Theme.of(context).textTheme.headlineMedium),
                Text(small, style: const TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ),
      );
}
