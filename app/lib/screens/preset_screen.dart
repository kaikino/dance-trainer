import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble/node_client.dart';
import '../models/preset.dart';
import '../models/session_kind.dart';
import '../store/history.dart';
import '../store/settings.dart';
import '../ui/step_legend.dart';
import '../ui/style.dart';
import 'calibrate_screen.dart';
import 'dance_screen.dart';
import 'history_screen.dart';
import 'sound_sync_dialog.dart';

export '../models/session_kind.dart';

class PresetScreen extends StatefulWidget {
  const PresetScreen({super.key, required this.manager});
  final NodeManager manager;

  @override
  State<PresetScreen> createState() => _PresetScreenState();
}

class _PresetScreenState extends State<PresetScreen> {
  List<Preset>? _presets;
  Preset? _selected;
  SessionKind _kind = SessionKind.values.where((k) => k.name == AppSettings.lastKind).firstOrNull ??
      SessionKind.performance;
  final _dancer = TextEditingController(text: 'dancer');

  /// Past sessions, for the best score on each card.
  List<HistoryEntry> _history = const [];
  Map<int, double> _best = const {};

  /// Practice starts a little slower, so a new routine can be learnt.
  static const practiceTempo = 0.8;

  /// The tempo for each mode, remembered between visits.
  double _tempoFor(SessionKind k) =>
      AppSettings.tempoByKind[k.name] ?? (k == SessionKind.practice ? practiceTempo : 1.0);
  double get _tempo => _tempoFor(_kind);
  set _tempo(double v) => AppSettings.tempoByKind[_kind.name] = v;

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
      _selected = presets.where((p) => p.id == AppSettings.lastPresetId).firstOrNull ?? presets.firstOrNull;
    });
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    final history = await SessionHistory.load();
    if (!mounted) return;
    setState(() {
      _history = history;
      _best = SessionHistory.bestByPreset(history);
    });
  }

  /// Remembers the routine, mode and tempo for next time.
  void _remember() {
    AppSettings.lastPresetId = _selected?.id;
    AppSettings.lastKind = _kind.name;
    AppSettings.save().catchError((_) {});
  }

  /// Connected nodes whose firmware says the toe direction is unknown or stale.
  List<NodeClient> get _needCalibration =>
      m.connectedNodes.where((n) => calStateOf(n.status).needsCalibration).toList();

  Future<void> _start({bool demo = false}) async {
    _remember();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DanceScreen(
          manager: m,
          preset: _selected!.withTempo(_tempo),
          kind: _kind,
          dancer: _dancer.text.trim().isEmpty ? 'dancer' : _dancer.text.trim(),
          demo: demo,
        ),
      ),
    );
    await _loadHistory();
  }

  Future<void> _openHistory(Preset p) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => HistoryScreen(preset: p)));
    await _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final presets = _presets;
    final noNodes = m.connectedNodes.isEmpty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a routine'),
        actions: [
          IconButton(
            onPressed: () => showStepLegend(context),
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: 'What the steps mean',
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: presets == null
          ? null
          : BottomActions(
              maxWidth: 1100,
              children: [
                FilledButton.icon(
                  onPressed: _selected == null || noNodes ? null : _start,
                  icon: Icon(noNodes ? Icons.bluetooth_disabled_rounded : Icons.play_arrow_rounded),
                  label: Text(
                    noNodes
                        ? 'Connect a node to start'
                        : 'Start ${_kind.title.toLowerCase()}'
                            // The tempo is on the screen above; a phone has no room for it here.
                            '${_selected == null || narrow ? '' : ' · ${(_selected!.bpm * _tempo).round()} bpm'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // No nodes needed: the chart and the music only.
                OutlinedButton.icon(
                  onPressed: _selected == null ? null : () => _start(demo: true),
                  icon: const Icon(Icons.visibility_rounded),
                  label: Text(narrow ? 'Watch' : 'Watch first', maxLines: 1, overflow: TextOverflow.ellipsis),
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
    final cards = [
      for (final p in presets)
        _RoutineCard(
          preset: p,
          selected: p == _selected,
          best: _best[p.id],
          sessions: _history.where((e) => e.presetId == p.id).length,
          fill: wide,
          onTap: () {
            setState(() => _selected = p);
            _remember();
          },
          onHistory: () => _openHistory(p),
        ),
    ];
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
              _remember();
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
    void set(double v, {bool save = false}) {
      setState(() => _tempo = v);
      if (save) _remember();
    }

    // Slow is Practice's starting tempo; Normal is as written.
    Widget preset(String label, double v) => ChoiceChip(
          label: Text(label),
          selected: (_tempo - v).abs() < 0.001,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          onSelected: (_) => set(v, save: true),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Tempo',
          trailing: Wrap(spacing: 8, children: [preset('Slow', practiceTempo), preset('Normal', 1.0)]),
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
            Text((_tempo - 1.0).abs() < 0.001 ? 'as written' : '${(_tempo * 100).round()}% speed',
                style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        MergeSemantics(
          child: Semantics(
            label: 'Tempo',
            child: Slider(
              semanticFormatterCallback: (v) =>
                  '${_selected == null ? '' : '${(_selected!.bpm * v).round()} bpm, '}${(v * 100).round()}% speed',
              value: _tempo,
              min: 0.6,
              max: 1.2,
              divisions: 12,
              label: bpm == null ? '${(_tempo * 100).round()}%' : '$bpm bpm',
              padding: const EdgeInsets.symmetric(vertical: 12),
              onChanged: set,
              onChangeEnd: (v) => set(v, save: true),
            ),
          ),
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
              if (mounted) setState(() {});
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
              onChanged: (v) {
                setState(() => _kind = v!);
                _remember();
              },
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

/// One routine: name, tempo and length, its first two bars as step icons,
/// and the best score so far with a link to its history.
class _RoutineCard extends StatelessWidget {
  const _RoutineCard({
    required this.preset,
    required this.selected,
    required this.onTap,
    required this.onHistory,
    this.best,
    this.sessions = 0,
    this.fill = false,
  });

  /// In a row of equal-height cards: the best-score line sits at the bottom.
  final bool fill;
  final Preset preset;
  final bool selected;
  final VoidCallback onTap, onHistory;
  final double? best;
  final int sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final b = best;
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
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: StepPatternPreview(preset: preset, color: selected ? scheme.primary : scheme.secondary),
                ),
                if (fill) const Spacer(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (b != null)
                      StatusPill(icon: Icons.emoji_events_rounded, text: 'Best ${(b * 100).round()}%', color: accuracyColor(context, b))
                    else
                      Text(sessions == 0 ? 'Not danced yet' : 'No full run yet',
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    const Spacer(),
                    if (sessions > 0)
                      TextButton.icon(
                        onPressed: onHistory,
                        icon: const Icon(Icons.history_rounded, size: 20),
                        label: const Text('History'),
                      )
                    else
                      const SizedBox(height: 48),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
