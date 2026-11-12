import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../ui/style.dart';
import 'calibrate_screen.dart';
import 'live_view_screen.dart';
import 'preset_screen.dart';

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

  void _openLiveView() =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => LiveViewScreen(manager: m)));

  void _snack(String s, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), action: action));
  }

  /// Calibrated well enough to judge directions (old firmware cannot say: assume so).
  static bool _calibrated(NodeClient n) {
    final st = n.status;
    return st == null || st.calFlags == null || (st.knowsForward && !st.boardMoved);
  }

  void _openRoutines() => Navigator.push(context, MaterialPageRoute(builder: (_) => PresetScreen(manager: m)));

  @override
  Widget build(BuildContext context) {
    final connected = m.nodes.where((n) => n.connected).toList();
    final allConnected = connected.length == m.nodes.length;
    final needCal = connected.where((n) => !_calibrated(n)).toList();
    final theme = Theme.of(context);

    // One filled (primary) button for the next thing to do, the rest outlined.
    final scan = (
      label: _scanning ? 'Scanning…' : (connected.isEmpty ? 'Scan for nodes' : 'Scan again'),
      icon: Icons.bluetooth_searching,
      onPressed: _scanning ? null : _scan,
    );
    final calibrate = (
      label: needCal.isEmpty ? 'Calibrate again' : (needCal.length == 2 ? 'Calibrate both feet' : 'Calibrate'),
      icon: Icons.straighten,
      onPressed: connected.isEmpty ? null : () => _calibrate(needCal.isEmpty ? connected : needCal),
    );
    final routine = (
      label: 'Choose a routine',
      icon: Icons.queue_music,
      onPressed: connected.isEmpty ? null : _openRoutines,
    );
    final (primary, secondary) = !allConnected
        ? (scan, [if (connected.isNotEmpty) routine])
        : needCal.isNotEmpty
            ? (calibrate, [routine])
            : (routine, [calibrate]);

    return Scaffold(
      appBar: AppBar(title: const Text('Dance Trainer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
                const SizedBox(height: 16),
                for (final n in m.nodes) _nodeCard(n),
                const SizedBox(height: 24),
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: primary.onPressed,
                    icon: _scanning && primary == scan
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(primary.icon),
                    label: Text(primary.label),
                  ),
                ),
                for (final b in secondary) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(onPressed: b.onPressed, icon: Icon(b.icon), label: Text(b.label)),
                  ),
                ],
                if (!allConnected && connected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Only one ankle connected: it will be judged alone.',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
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
    const warn = Color(0xFFE65100);
    final calPill = switch (st) {
      null || Status(calFlags: null) => null,
      Status(boardMoved: true) => const StatusPill(icon: Icons.error_outline, text: 'Board moved', color: warn),
      Status(knowsForward: true) => StatusPill(icon: Icons.check_circle, text: 'Calibrated', color: Verdict.correct.color),
      Status(calibrated: true) => const StatusPill(icon: Icons.error_outline, text: 'Tilt only', color: warn),
      _ => const StatusPill(icon: Icons.error_outline, text: 'Needs calibration', color: warn),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: n.connected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: n.connected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                  child: Text(n.roleLabel, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${footName(n.role)} ankle', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (!n.connected)
                            const StatusPill(icon: Icons.bluetooth_disabled, text: 'Not connected')
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
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => _calibrate([n]),
                    icon: const Icon(Icons.straighten, size: 18),
                    label: const Text('Calibrate'),
                  ),
                  TextButton.icon(
                    onPressed: _openLiveView,
                    icon: const Icon(Icons.threed_rotation, size: 18),
                    label: const Text('Live view'),
                  ),
                  TextButton.icon(
                    onPressed: () => n.buzzTest(Haptic.double),
                    icon: const Icon(Icons.vibration, size: 18),
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
        >= 90 => Icons.battery_full,
        >= 60 => Icons.battery_5_bar,
        >= 35 => Icons.battery_3_bar,
        >= 15 => Icons.battery_2_bar,
        _ => Icons.battery_alert,
      };
}
