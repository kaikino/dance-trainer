import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../store/settings.dart';
import '../ui/style.dart';
import 'calibrate_screen.dart';
import 'live_view_screen.dart';
import 'onboarding_screen.dart';
import 'preset_screen.dart';
import 'recordings_screen.dart';

/// Find both nodes and calibrate them. Entry screen. (Clocks are synced at the start of each session.)
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.manager});
  final NodeManager manager;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  NodeManager get m => widget.manager;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    m.addListener(_onChange);
    // First run: how to wear the nodes, once.
    if (!AppSettings.onboardingSeen) WidgetsBinding.instance.addPostFrameCallback((_) => _openOnboarding());
  }

  Future<void> _openOnboarding() async {
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => OnboardingScreen(manager: m)));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    m.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final found = await m.scanAndConnect();
      if (found == 0) _snack('No nodes found. Check that both are switched on and close by, then scan again.');
    } on BleUnavailable catch (e) {
      _snack(e.message,
          action: e.adapterOff && Platform.isAndroid
              ? SnackBarAction(label: 'Turn on', onPressed: () => FlutterBluePlus.turnOn().catchError((_) {}))
              : null);
    } catch (e) {
      _snack('Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _calibrate(List<NodeClient> nodes) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CalibrateScreen(manager: m, nodes: nodes)),
    );
    if (mounted) setState(() {});
  }

  void _openLiveView() => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveViewScreen(manager: m)));

  void _snack(String s, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), action: action));
  }

  /// Calibrated well enough to judge directions (old firmware cannot say: assume so).
  static bool _calibrated(NodeClient n) => !calStateOf(n.status).needsCalibration;

  void _openRoutines() => Navigator.push(context, PresetScreen.route(m));

  @override
  Widget build(BuildContext context) {
    final connected = m.nodes.where((n) => n.connected).toList();
    final allConnected = connected.length == m.nodes.length;
    final needCal = connected.where((n) => !_calibrated(n)).toList();
    final theme = Theme.of(context);

    // One filled (primary) button for the next thing to do, the rest outlined.
    final scan = (
      label: _scanning ? 'Scanning…' : (connected.isEmpty ? 'Scan for nodes' : 'Scan again'),
      icon: Icons.bluetooth_searching_rounded,
      onPressed: _scanning ? null : _scan,
    );
    final calibrate = (
      label: needCal.isEmpty ? 'Calibrate again' : (needCal.length == 2 ? 'Calibrate both feet' : 'Calibrate'),
      icon: Icons.straighten_rounded,
      onPressed: connected.isEmpty ? null : () => _calibrate(needCal.isEmpty ? connected : needCal),
    );
    final routine = (
      label: 'Choose a routine',
      icon: Icons.queue_music_rounded,
      onPressed: connected.isEmpty ? null : _openRoutines,
    );
    final (primary, secondary) = !allConnected
        ? (scan, [if (connected.isNotEmpty) routine])
        : needCal.isNotEmpty
            ? (calibrate, [routine])
            : (routine, [calibrate]);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dance Trainer'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RecordingsScreen())),
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('Recordings'),
          ),
          TextButton.icon(
            onPressed: _openOnboarding,
            icon: const Icon(Icons.help_outline_rounded),
            label: const Text('How to wear'),
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      bottomNavigationBar: BottomActions(
        stackOnPhone: true,
        children: [
          FilledButton.icon(
            onPressed: primary.onPressed,
            icon: _scanning && primary == scan
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(primary.icon),
            label: Text(primary.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          for (final b in secondary)
            OutlinedButton.icon(
              onPressed: b.onPressed,
              icon: Icon(b.icon),
              label: Text(b.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(Space.gutter(context)),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  m.fake
                      ? 'Simulated nodes (FAKE_NODES build). Scan connects two fake ankles.'
                      : 'Switch both ankle nodes on, then scan.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: Space.lg),
                for (final n in m.nodes) _nodeCard(n),
                if (!allConnected && connected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text('Only one ankle connected: it will be judged alone.',
                        style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _nodeCard(NodeClient n) {
    final st = n.status;
    final theme = Theme.of(context);
    final warn = StatusColors.warn(context);
    final calPill = switch (calStateOf(st)) {
      CalState.unknown => null,
      CalState.boardMoved => StatusPill(icon: Icons.error_rounded, text: 'Board moved', color: warn),
      CalState.calibrated =>
        StatusPill(icon: Icons.check_circle_rounded, text: 'Calibrated', color: StatusColors.ok(context)),
      CalState.tiltOnly => StatusPill(icon: Icons.error_rounded, text: 'Tilt only', color: warn),
      CalState.notCalibrated => StatusPill(icon: Icons.error_rounded, text: 'Needs calibration', color: warn),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: Space.md),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: n.connected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: n.connected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                  child: Text(n.roleLabel,
                      style: theme.textTheme.titleLarge?.copyWith(
                          color: n.connected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                          fontWeight: AppType.heavy)),
                ),
                const SizedBox(width: Space.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${footName(n.role)} ankle', style: theme.textTheme.titleLarge),
                      const SizedBox(height: Space.sm),
                      Wrap(
                        spacing: Space.sm,
                        runSpacing: Space.sm,
                        children: [
                          if (!n.connected)
                            const StatusPill(icon: Icons.bluetooth_disabled_rounded, text: 'Not connected')
                          else ...[
                            if (st != null) StatusPill(icon: _batteryIcon(st.batteryPct), text: '${st.batteryPct}%'),
                            if (calPill != null) calPill,
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (n.connected) ...[
              const SizedBox(height: Space.md),
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.xs,
                children: [
                  TextButton.icon(
                    onPressed: () => _calibrate([n]),
                    icon: const Icon(Icons.straighten_rounded, size: 18),
                    label: const Text('Calibrate'),
                  ),
                  TextButton.icon(
                    onPressed: _openLiveView,
                    icon: const Icon(Icons.threed_rotation_rounded, size: 18),
                    label: const Text('Live view'),
                  ),
                  TextButton.icon(
                    onPressed: () => n.buzzTest(Haptic.long),   // 400 ms: a short pulse barely spins the motor up
                    icon: const Icon(Icons.vibration_rounded, size: 18),
                    label: const Text('Buzz'),
                  ),
                ],
              ),
              if (st != null)
                Text('Firmware ${st.fwVersion >> 8}.${st.fwVersion & 0xff}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _batteryIcon(int pct) => switch (pct) {
        >= 90 => Icons.battery_full_rounded,
        >= 60 => Icons.battery_5_bar_rounded,
        >= 35 => Icons.battery_3_bar_rounded,
        >= 15 => Icons.battery_2_bar_rounded,
        _ => Icons.battery_alert_rounded,
      };
}
