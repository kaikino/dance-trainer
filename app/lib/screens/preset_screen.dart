import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../models/preset.dart';
import '../store/settings.dart';
import '../ui/style.dart';
import 'calibrate_screen.dart';
import 'dance_screen.dart';
import 'sound_sync_dialog.dart';

/// How a session behaves. Capture and Dance are the node's modes; Practice and
/// Performance are both node mode `dance`, differing only in what the app does
/// on a mistake.
enum SessionKind { capture, performance, practice }

extension SessionKindX on SessionKind {
  Mode get nodeMode => this == SessionKind.capture ? Mode.capture : Mode.dance;
  String get title => switch (this) {
        SessionKind.capture => 'Capture',
        SessionKind.performance => 'Performance',
        SessionKind.practice => 'Practice',
      };
  String get description => switch (this) {
        SessionKind.capture => 'Record raw sensor data for training the step classifier',
        SessionKind.performance => 'Dance it through, scored at the end',
        SessionKind.practice => 'Stop on a mistake and go back one bar',
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

  @override
  void dispose() {
    _dancer.dispose();
    super.dispose();
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

  /// Connected nodes whose firmware says the toe direction is unknown or stale.
  List<NodeClient> get _needCalibration => widget.manager.nodes.where((n) {
        final st = n.status;
        return n.connected && st != null && st.calFlags != null && (!st.knowsForward || st.boardMoved);
      }).toList();

  void _start() => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DanceScreen(
            manager: widget.manager,
            preset: _selected!.withTempo(_tempo),
            kind: _kind,
            dancer: _dancer.text.trim().isEmpty ? 'dancer' : _dancer.text.trim(),
          ),
        ),
      );

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    final presets = _presets;
    final theme = Theme.of(context);
    final needCal = _needCalibration;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a routine')),
      bottomNavigationBar: presets == null
          ? null
          : Material(
              elevation: 3,
              color: theme.colorScheme.surfaceContainer,
              child: ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _selected == null ? null : _start,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text('Start ${_kind.title.toLowerCase()}'),
                    ),
                  ),
                ),
              ),
            ),
      body: presets == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                ContentWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (needCal.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Card(
                            color: theme.colorScheme.errorContainer,
                            child: ListTile(
                              leading: const Icon(Icons.warning_amber),
                              title: Text('${needCal.map((n) => footName(n.role)).join(' and ')} '
                                  '${needCal.length == 1 ? 'ankle needs' : 'ankles need'} calibrating'),
                              subtitle: const Text('Steps will be judged in the wrong direction until then.'),
                              trailing: FilledButton(
                                onPressed: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => CalibrateScreen(
                                          manager: widget.manager, nodes: needCal, returnToRoutine: true),
                                    ),
                                  );
                                  if (mounted) setState(() {});
                                },
                                child: const Text('Calibrate'),
                              ),
                            ),
                          ),
                        ),
                      _header('Routine'),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: RadioGroup<Preset>(
                          groupValue: _selected,
                          onChanged: (v) => setState(() => _selected = v),
                          child: Column(
                            children: [
                              for (final p in presets)
                                RadioListTile<Preset>(
                                  value: p,
                                  title: Text(p.name, style: theme.textTheme.titleMedium),
                                  subtitle: Text('${p.bpm.round()} bpm · ${p.bars} bars · '
                                      '${(p.lastBeat * p.beatMs / 1000).round()} s'),
                                ),
                            ],
                          ),
                        ),
                      ),
                      _header('Mode'),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: RadioGroup<SessionKind>(
                          groupValue: _kind,
                          onChanged: (v) => setState(() => _kind = v!),
                          child: Column(
                            children: [
                              for (final k in [SessionKind.performance, SessionKind.practice])
                                RadioListTile<SessionKind>(
                                  value: k,
                                  title: Text(k.title, style: theme.textTheme.titleMedium),
                                  subtitle: Text(k.description),
                                ),
                            ],
                          ),
                        ),
                      ),
                      _header('Tempo ${(_tempo * 100).round()}%'),
                      Slider(
                        value: _tempo,
                        min: 0.6,
                        max: 1.2,
                        divisions: 12,
                        label: '${(_tempo * 100).round()}%',
                        onChanged: (v) => setState(() => _tempo = v),
                      ),
                      _header('Sound'),
                      Card(
                        child: ListTile(
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
                      ),
                      const SizedBox(height: 16),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          leading: const Icon(Icons.tune),
                          title: const Text('Advanced'),
                          subtitle: const Text('Recording for training'),
                          initiallyExpanded: _kind == SessionKind.capture,
                          shape: const Border(),
                          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          children: [
                            RadioGroup<SessionKind>(
                              groupValue: _kind,
                              onChanged: (v) => setState(() => _kind = v!),
                              child: RadioListTile<SessionKind>(
                                contentPadding: EdgeInsets.zero,
                                value: SessionKind.capture,
                                title: Text(SessionKind.capture.title),
                                subtitle: Text(SessionKind.capture.description),
                              ),
                            ),
                            TextField(
                              controller: _dancer,
                              decoration: const InputDecoration(labelText: 'Dancer name (for the recording)'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
