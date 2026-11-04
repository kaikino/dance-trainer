import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';
import '../store/settings.dart';
import 'dance_screen.dart';
import 'sound_sync_dialog.dart';

/// How a session behaves. Capture and Dance are the node's modes; Practice and
/// Performance are both node mode `dance`, differing only in what the app does
/// on a mistake.
enum SessionKind { capture, performance, practice }

extension SessionKindX on SessionKind {
  Mode get nodeMode => this == SessionKind.capture ? Mode.capture : Mode.dance;
  String get label => switch (this) {
        SessionKind.capture => 'Capture (record for training)',
        SessionKind.performance => 'Performance (keep going, score)',
        SessionKind.practice => 'Practice (pause and rewind on a mistake)',
      };
}

class PresetScreen extends StatefulWidget {
  const PresetScreen({super.key, required this.manager});
  final NodeManager manager;

  @override
  State<PresetScreen> createState() => _PresetScreenState();
}

class _PresetScreenState extends State<PresetScreen> {
  List<Preset>? _presets;
  Preset? _selected;
  SessionKind _kind = SessionKind.performance;
  final _dancer = TextEditingController(text: 'dancer');
  double _tempo = 1.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest.listAssets().where((p) => p.startsWith('assets/presets/') && p.endsWith('.json')).toList()
      ..sort();
    final presets = [for (final p in paths) await Preset.loadAsset(p)];
    setState(() {
      _presets = presets;
      _selected = presets.firstOrNull;
    });
  }

  @override
  Widget build(BuildContext context) {
    final presets = _presets;
    return Scaffold(
      appBar: AppBar(title: const Text('Routine')),
      body: presets == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                RadioGroup<Preset>(
                  groupValue: _selected,
                  onChanged: (v) => setState(() => _selected = v),
                  child: Column(
                    children: [
                      for (final p in presets)
                        RadioListTile<Preset>(
                          value: p,
                          title: Text(p.name),
                          subtitle: Text('${p.bpm.round()} bpm, ${p.steps.length} steps, '
                              '${(p.lastBeat * p.beatMs / 1000).round()} s'),
                        ),
                    ],
                  ),
                ),
                const Divider(),
                Text('Tempo ${(_tempo * 100).round()}%', style: Theme.of(context).textTheme.titleSmall),
                Slider(
                  value: _tempo,
                  min: 0.6,
                  max: 1.2,
                  divisions: 12,
                  label: '${(_tempo * 100).round()}%',
                  onChanged: (v) => setState(() => _tempo = v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.graphic_eq),
                  title: const Text('Sound sync'),
                  subtitle: Text(AppSettings.audioDelayMeasured
                      ? 'Sound delay ${AppSettings.audioDelayMs} ms'
                      : 'Not measured on this device yet (using ${AppSettings.audioDelayMs} ms)'),
                  trailing: OutlinedButton(
                    onPressed: () async {
                      await SoundSyncDialog.show(context);
                      setState(() {});
                    },
                    child: const Text('Test'),
                  ),
                ),
                const Divider(),
                RadioGroup<SessionKind>(
                  groupValue: _kind,
                  onChanged: (v) => setState(() => _kind = v!),
                  child: Column(
                    children: [
                      for (final k in SessionKind.values)
                        RadioListTile<SessionKind>(value: k, title: Text(k.label)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _dancer,
                  decoration: const InputDecoration(labelText: 'Dancer name (for the recording)'),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _selected == null
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DanceScreen(
                                manager: widget.manager,
                                preset: _selected!.withTempo(_tempo),
                                kind: _kind,
                                dancer: _dancer.text.trim().isEmpty ? 'dancer' : _dancer.text.trim(),
                              ),
                            ),
                          ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ],
            ),
    );
  }
}
