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
        SessionKind.performance => 'Dance it straight through and get scored at the end.',
        SessionKind.practice => 'Stops on a wrong or missed step and goes back to the start of that bar.',
      };
  IconData get icon => switch (this) {
        SessionKind.practice => Icons.school_rounded,
        SessionKind.performance => Icons.emoji_events_rounded,
        SessionKind.capture => Icons.fiber_manual_record_rounded,
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

  NodeManager get m => widget.manager;

  @override
  void initState() {
    super.initState();
    m.addListener(_onNodes);
    _load();
  }

  @override
  void dispose() {
    m.removeListener(_onNodes);
    _dancer.dispose();
    super.dispose();
  }

  void _onNodes() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest.listAssets().where((p) => p.startsWith('assets/presets/') && p.endsWith('.json')).toList()
      ..sort();
    final presets = [for (final p in paths) await Preset.loadAsset(p)];
    if (!mounted) return;
    setState(() {
      _presets = presets;
      _selected = presets.firstOrNull;
    });
  }

  /// Connected nodes whose firmware says the toe direction is unknown or stale.
  List<NodeClient> get _needCalibration => m.connectedNodes.where((n) {
        final st = n.status;
        return st != null && st.calFlags != null && (!st.knowsForward || st.boardMoved);
      }).toList();

  void _start() => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DanceScreen(
            manager: m,
            preset: _selected!.withTempo(_tempo),
            kind: _kind,
            dancer: _dancer.text.trim().isEmpty ? 'dancer' : _dancer.text.trim(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final presets = _presets;
    final noNodes = m.connectedNodes.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a routine')),
      bottomNavigationBar: presets == null
          ? null
          : BottomActions(
              maxWidth: 1100,
              children: [
                FilledButton.icon(
                  onPressed: _selected == null || noNodes ? null : _start,
                  icon: Icon(noNodes ? Icons.bluetooth_disabled_rounded : Icons.play_arrow_rounded),
                  label: Text(noNodes
                      ? 'Connect a node to start'
                      : 'Start ${_kind.title.toLowerCase()}${_selected == null ? '' : ' · ${(_selected!.bpm * _tempo).round()} bpm'}'),
                ),
              ],
            ),
      body: presets == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 900;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  ContentWidth(
                    maxWidth: wide ? 1100 : 720,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ..._warnings(context),
                        const SectionHeader('Routine'),
                        _routines(presets, wide),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _mode(context)),
                              const SizedBox(width: 24),
                              Expanded(child: _tempoSection(context)),
                            ],
                          )
                        else ...[
                          _mode(context),
                          _tempoSection(context),
                        ],
                        const SectionHeader('More'),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _sound(context)),
                              const SizedBox(width: 12),
                              Expanded(child: _advanced(context)),
                            ],
                          )
                        else ...[
                          _sound(context),
                          const SizedBox(height: 12),
                          _advanced(context),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            }),
    );
  }

  List<Widget> _warnings(BuildContext context) {
    final theme = Theme.of(context);
    final needCal = _needCalibration;
    Widget card(IconData icon, String title, String subtitle, Widget? action) => Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: Icon(icon, color: theme.colorScheme.onErrorContainer),
              title: Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.onErrorContainer, fontWeight: FontWeight.w700)),
              subtitle: Text(subtitle, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              trailing: action,
            ),
          ),
        );
    return [
      if (m.connectedNodes.isEmpty)
        card(Icons.bluetooth_disabled_rounded, 'No ankle node connected',
            'Go back and scan for the nodes; steps cannot be judged without them.', null),
      if (needCal.isNotEmpty)
        card(
          Icons.warning_amber_rounded,
          '${needCal.map((n) => footName(n.role)).join(' and ')} '
              '${needCal.length == 1 ? 'ankle needs' : 'ankles need'} calibrating',
          'Steps will be judged in the wrong direction until then.',
          FilledButton(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => CalibrateScreen(manager: m, nodes: needCal, returnToRoutine: true)),
              );
              if (mounted) setState(() {});
            },
            child: const Text('Calibrate'),
          ),
        ),
    ];
  }

  Widget _routines(List<Preset> presets, bool wide) {
    final cards = [for (final p in presets) _RoutineCard(preset: p, selected: p == _selected, onTap: () => setState(() => _selected = p))];
    if (!wide) {
      return Column(
        children: [for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: 12), child: c)],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }

  Widget _mode(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Mode'),
        SizedBox(
          height: 56,
          child: SegmentedButton<SessionKind>(
            segments: [
              for (final k in [SessionKind.performance, SessionKind.practice])
                ButtonSegment(value: k, label: Text(k.title), icon: Icon(k.icon)),
            ],
            selected: {if (_kind != SessionKind.capture) _kind},
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            onSelectionChanged: (s) {
              if (s.isNotEmpty) setState(() => _kind = s.first);
            },
          ),
        ),
        const SizedBox(height: 10),
        Text(_kind.description,
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _tempoSection(BuildContext context) {
    final theme = Theme.of(context);
    final bpm = _selected == null ? null : (_selected!.bpm * _tempo).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Tempo',
          trailing: _tempo == 1.0
              ? null
              : TextButton(onPressed: () => setState(() => _tempo = 1.0), child: const Text('Reset')),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(bpm == null ? '–' : '$bpm',
                style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: theme.colorScheme.primary)),
            const SizedBox(width: 6),
            Text('bpm', style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.primary)),
            const Spacer(),
            Text(_tempo == 1.0 ? 'as written' : '${(_tempo * 100).round()}% speed',
                style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        Slider(
          value: _tempo,
          min: 0.6,
          max: 1.2,
          divisions: 12,
          label: bpm == null ? '${(_tempo * 100).round()}%' : '$bpm bpm',
          padding: const EdgeInsets.symmetric(vertical: 12),
          onChanged: (v) => setState(() => _tempo = v),
        ),
      ],
    );
  }

  Widget _sound(BuildContext context) => Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: const Icon(Icons.graphic_eq_rounded),
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
      );

  Widget _advanced(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: const Icon(Icons.tune_rounded),
          title: const Text('Advanced'),
          subtitle: Text(_kind == SessionKind.capture ? 'Capture selected' : 'Recording for training'),
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
      );
}

/// One routine: name, tempo and length, and its first two bars as step icons.
class _RoutineCard extends StatelessWidget {
  const _RoutineCard({required this.preset, required this.selected, required this.onTap});
  final Preset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(preset.name,
                          style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800, color: selected ? scheme.onPrimaryContainer : null)),
                    ),
                    Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                        color: selected ? scheme.primary : scheme.outline),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${preset.bpm.round()} bpm · ${preset.bars} bars · ${(preset.lastBeat * preset.beatMs / 1000).round()} s',
                    style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: StepPatternPreview(preset: preset, color: selected ? scheme.primary : scheme.secondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
