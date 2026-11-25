import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/song_preview.dart';
import '../ble/node_client.dart';
import '../models/preset.dart';
import '../models/session_kind.dart';
import '../store/training_session.dart';
import 'recordings_screen.dart';
import '../store/history.dart';
import '../store/settings.dart';
import '../ui/route_observer.dart';
import '../ui/song_carousel.dart';
import '../ui/step_legend.dart';
import '../ui/style.dart';
import 'calibrate_screen.dart';
import 'dance_screen.dart';
import 'history_screen.dart';
import 'sound_sync_dialog.dart';
import '../store/app_dirs.dart';

export '../models/session_kind.dart';

class PresetScreen extends StatefulWidget {
  const PresetScreen({super.key, required this.manager});
  final NodeManager manager;

  /// Route name, so a recording's summary can come back here.
  static const routeName = '/routine';
  static MaterialPageRoute<void> route(NodeManager manager) =>
      MaterialPageRoute(settings: const RouteSettings(name: routeName), builder: (_) => PresetScreen(manager: manager));

  @override
  State<PresetScreen> createState() => _PresetScreenState();
}

class _PresetScreenState extends State<PresetScreen> with WidgetsBindingObserver, RouteAware {
  List<Preset>? _presets;
  Preset? _selected;
  SessionKind _kind =
      SessionKind.values.where((k) => k.name == AppSettings.lastKind).firstOrNull ?? SessionKind.performance;
  final _dancer = TextEditingController(text: 'dancer');

  /// Past sessions, for the best score on each card.
  Map<int, int> _sessions = const {};
  Map<int, double> _best = const {};

  /// The routine in the middle of the carousel plays while this screen is
  /// in front (and the app is).
  final _preview = SongPreview();

  /// Another screen (or a dialog) covers this one: no preview until it is
  /// back in front (RouteAware below).
  bool _away = false;

  /// What the preview is playing, for tests.
  @visibleForTesting
  Preset? get previewing => _preview.current;

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
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Coming in with recording mode on starts a new training session.
    if (_kind == SessionKind.capture) _startTraining();
  }

  Future<void> _startTraining() async {
    try {
      await TrainingSession.start(_dancerName);
    } catch (e) {
      debugPrint('no training session: $e'); // no shared storage (tests, desktop)
    }
    if (mounted) setState(() {});
  }

  String get _dancerName => _dancer.text.trim().isEmpty ? 'dancer' : _dancer.text.trim();

  /// Switching mode: into recording opens a new training session, out of it closes it.
  void _setKind(SessionKind k) {
    if (k == _kind) return;
    if (k == SessionKind.capture) {
      _startTraining();
    } else if (_kind == SessionKind.capture) {
      TrainingSession.close();
    }
    setState(() => _kind = k);
    _remember();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  // Covered by another screen: silence. A run's summary replaces the dance
  // screen and Try again replaces the summary, so this screen is not back in
  // front until all of those are gone (didPopNext): the preview must not come
  // back just because the screen it opened was replaced.
  @override
  void didPushNext() {
    _away = true;
    _preview.stop();
  }

  @override
  void didPopNext() {
    _away = false;
    _playPreview();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    m.removeListener(_onNodes);
    WidgetsBinding.instance.removeObserver(this);
    _preview.dispose();
    _dancer.dispose();
    TrainingSession.close();
    super.dispose();
  }

  void _onNodes() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _playPreview();
    } else if (state != AppLifecycleState.inactive) {
      _preview.stop(); // in the background: silence
    }
  }

  /// Plays the selected routine at the chosen tempo, unless muted or another
  /// screen is in front.
  void _playPreview() {
    final p = _selected;
    if (p == null || _away || !mounted) return;
    if (AppSettings.musicPreview) {
      _preview.play(p.withTempo(_tempo));
    } else {
      _preview.stop();
    }
  }

  /// Opens another screen. The preview stops and starts again by itself
  /// (didPushNext / didPopNext), whatever that screen goes on to open.
  Future<T?> _push<T>(Route<T> route) => Navigator.push(context, route);

  void _select(int i) {
    final p = _presets![i];
    if (p == _selected) return;
    setState(() => _selected = p);
    _remember();
    _playPreview();
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
    _playPreview();
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    final history = await SessionHistory.load();
    if (!mounted) return;
    setState(() {
      _sessions = {};
      for (final e in history) {
        _sessions[e.presetId] = (_sessions[e.presetId] ?? 0) + 1;
      }
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
    await _push(
      MaterialPageRoute(
        builder: (_) => DanceScreen(
          manager: m,
          preset: _selected!.withTempo(_tempo),
          kind: _kind,
          dancer: _dancerName,
          demo: demo,
        ),
      ),
    );
    await _loadHistory();
  }

  Future<void> _openHistory(Preset p) async {
    await _push(MaterialPageRoute(builder: (_) => HistoryScreen(preset: p)));
    await _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final presets = _presets;
    final noNodes = m.connectedNodes.isEmpty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final index = presets == null || _selected == null ? 0 : presets.indexOf(_selected!);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a routine'),
        actions: [
          IconButton(
            onPressed: () {
              setState(() => AppSettings.musicPreview = !AppSettings.musicPreview);
              AppSettings.save().catchError((_) {});
              _playPreview();
            },
            isSelected: AppSettings.musicPreview,
            icon: const Icon(Icons.music_off_rounded),
            selectedIcon: const Icon(Icons.music_note_rounded),
            tooltip: AppSettings.musicPreview ? 'Music preview on' : 'Music preview off',
          ),
          IconButton(
            onPressed: () => showStepLegend(context),
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: 'What the steps mean',
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      bottomNavigationBar: presets == null
          ? null
          : BottomActions(
              maxWidth: 1100,
              children: [
                // No nodes: Watch first (the chart, floor map and music, nothing
                // judged) is the one thing to do.
                if (noNodes)
                  FilledButton(
                    onPressed: _selected == null ? null : () => _start(demo: true),
                    child: const Text('Watch first'),
                  )
                else
                  FilledButton(
                    onPressed: _selected == null ? null : _start,
                    child: Text('Start ${_kind.title.toLowerCase()}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                // No nodes needed: the chart and the music only. On a phone
                // just the eye, so Start keeps its words.
                if (!noNodes && MediaQuery.sizeOf(context).width < 430)
                  Tooltip(
                    message: 'Watch first',
                    child: OutlinedButton(
                      onPressed: _selected == null ? null : () => _start(demo: true),
                      child: const Icon(Icons.visibility_rounded, semanticLabel: 'Watch first'),
                    ),
                  )
                else if (!noNodes)
                  OutlinedButton(
                    onPressed: _selected == null ? null : () => _start(demo: true),
                    child: Text(narrow ? 'Watch' : 'Watch first', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
      body: presets == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 900;
              final gutter = Space.gutter(context);
              Widget column(List<Widget> children) => Padding(
                    padding: EdgeInsets.symmetric(horizontal: gutter),
                    child: ContentWidth(
                      maxWidth: wide ? 1100 : 720,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                    ),
                  );
              return ListView(
                padding: const EdgeInsets.only(bottom: Space.xl),
                children: [
                  column([
                    ..._warnings(context),
                    if (_kind == SessionKind.capture) _training(context),
                  ]),
                  const SizedBox(height: Space.sm),
                  SongCarousel(
                    presets: presets,
                    index: index < 0 ? 0 : index,
                    onChanged: _select,
                    onHistory: _openHistory,
                    best: _best,
                    sessions: _sessions,
                    tempo: _tempo,
                    height: wide ? 440 : (narrow ? 400 : 420),
                  ),
                  column([
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _mode(context)),
                          const SizedBox(width: Space.xl),
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
                          const SizedBox(width: Space.md),
                          Expanded(child: _advanced(context)),
                        ],
                      )
                    else ...[
                      _sound(context),
                      const SizedBox(height: Space.md),
                      _advanced(context),
                    ],
                  ]),
                ],
              );
            }),
    );
  }

  /// Recording mode: the training session every recorded run is saved to.
  Widget _training(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: TrainingSession.current,
      builder: (context, t, _) => Padding(
        padding: const EdgeInsets.only(top: Space.lg),
        child: Card(
          color: theme.colorScheme.secondaryContainer,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
            leading: Icon(Icons.fiber_manual_record_rounded, color: theme.colorScheme.error),
            title: Text(t == null ? 'Starting a training session…' : 'Training session · ${t.runs} runs saved',
                style: theme.textTheme.titleMedium),
            subtitle: Text(t == null
                ? ''
                : 'Every recorded run is saved to ${AppDirs.describe(t.dir.path)}. '
                    'Discard a bad run on its summary.'),
            trailing: Wrap(
              spacing: Space.sm,
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await _push(MaterialPageRoute(builder: (_) => const RecordingsScreen()));
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Recordings'),
                ),
                OutlinedButton(onPressed: _startTraining, child: const Text('New session')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _warnings(BuildContext context) {
    final theme = Theme.of(context);
    final needCal = _needCalibration;
    Widget card(IconData icon, String title, String subtitle, Widget? action) => Padding(
          padding: const EdgeInsets.only(top: Space.lg),
          child: Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
              leading: Icon(icon, color: theme.colorScheme.onErrorContainer),
              title:
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onErrorContainer)),
              subtitle: Text(subtitle, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              trailing: action,
            ),
          ),
        );
    return [
      if (m.connectedNodes.isEmpty)
        card(Icons.bluetooth_disabled_rounded, 'No ankle node connected',
            'Watch first plays the routine without them. Scan on the home screen to dance it and be judged.', null),
      if (needCal.isNotEmpty)
        card(
          Icons.warning_amber_rounded,
          '${needCal.map((n) => footName(n.role)).join(' and ')} '
              '${needCal.length == 1 ? 'ankle needs' : 'ankles need'} calibrating',
          'Steps will be judged in the wrong direction until then.',
          FilledButton(
            onPressed: () async {
              await _push(
                MaterialPageRoute(builder: (_) => CalibrateScreen(manager: m, nodes: needCal, returnToRoutine: true)),
              );
              if (mounted) setState(() {});
            },
            child: const Text('Calibrate'),
          ),
        ),
    ];
  }

  Widget _mode(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Mode'),
        SizedBox(
          height: Sizes.button,
          child: SegmentedButton<SessionKind>(
            segments: [
              for (final k in [SessionKind.performance, SessionKind.practice])
                ButtonSegment(value: k, label: Text(k.title)),
            ],
            selected: {if (_kind != SessionKind.capture) _kind},
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              if (s.isNotEmpty) _setKind(s.first);
            },
          ),
        ),
        const SizedBox(height: Space.sm),
        Text(_kind.description, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _tempoSection(BuildContext context) {
    final theme = Theme.of(context);
    final bpm = _selected == null ? null : (_selected!.bpm * _tempo).round();
    void set(double v, {bool save = false}) {
      setState(() => _tempo = v);
      if (save) {
        _remember();
        _playPreview(); // at the new tempo
      }
    }

    // Slow is Practice's starting tempo; Normal is as written. The same
    // toggle style as the mode above.
    final presets = {'Slow': practiceTempo, 'Normal': 1.0};
    final current = presets.entries.where((e) => (_tempo - e.value).abs() < 0.001).map((e) => e.value).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Tempo',
          trailing: SegmentedButton<double>(
            segments: [for (final e in presets.entries) ButtonSegment(value: e.value, label: Text(e.key))],
            selected: current,
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (sel) {
              if (sel.isNotEmpty) set(sel.first, save: true);
            },
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(bpm == null ? '–' : '$bpm', style: theme.textTheme.display.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(width: Space.sm),
            Text('bpm', style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.primary)),
            const Spacer(),
            // Only when it differs from the routine as written.
            if ((_tempo - 1.0).abs() >= 0.001)
              Text('${(_tempo * 100).round()}%',
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
              padding: const EdgeInsets.symmetric(vertical: Space.md),
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
          contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
          leading: const Icon(Icons.graphic_eq_rounded),
          title: const Text('Sound sync'),
          subtitle: Text(AppSettings.audioDelayMeasured
              ? 'Sound delay ${AppSettings.audioDelayMs} ms'
              : 'Not measured on this device yet (using ${AppSettings.audioDelayMs} ms)'),
          trailing: OutlinedButton(
            onPressed: () async {
              // The test plays its own clicks; the dialog covers this screen,
              // so the preview stops while it is open (didPushNext).
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
          childrenPadding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          children: [
            RadioGroup<SessionKind>(
              groupValue: _kind,
              onChanged: (v) => _setKind(v!),
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
