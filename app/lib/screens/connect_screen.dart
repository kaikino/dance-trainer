import 'package:flutter/material.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import 'calibrate_screen.dart';
import 'live_view_screen.dart';
import 'preset_screen.dart';

/// Find both nodes, calibrate them, sync clocks. Entry screen.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.manager});
  final NodeManager manager;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  NodeManager get m => widget.manager;
  bool _scanning = false;
  final _synced = <Role, int>{};

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
      await m.scanAndConnect();
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

  Future<void> _sync(NodeClient n) async {
    try {
      final off = await n.syncTime();
      setState(() => _synced[n.role] = off);
    } catch (e) {
      _snack('Time sync failed: $e');
    }
  }

  void _openLiveView() =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => LiveViewScreen(manager: m)));

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final anyConnected = m.nodes.any((n) => n.connected);
    return Scaffold(
      appBar: AppBar(title: const Text('Dance Trainer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(m.fake
              ? 'Simulated nodes (FAKE_NODES build). Scan connects two fake ankles.'
              : 'Switch both ankle nodes on, then scan.'),
          const SizedBox(height: 12),
          for (final n in m.nodes) _nodeCard(n),
          if (m.nodes.every((n) => n.connected)) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _calibrate(m.nodes),
              icon: const Icon(Icons.straighten),
              label: const Text('Calibrate both feet'),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: anyConnected
                ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => PresetScreen(manager: m)))
                : null,
            icon: const Icon(Icons.queue_music),
            label: const Text('Choose a routine'),
          ),
          if (!anyConnected)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Connect at least one node first.', style: TextStyle(color: Colors.grey)),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _scan,
        icon: _scanning
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.bluetooth_searching),
        label: Text(_scanning ? 'Scanning' : 'Scan'),
      ),
    );
  }

  Widget _nodeCard(NodeClient n) {
    final st = n.status;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(child: Text(n.roleLabel)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.roleLabel == 'L' ? 'Left ankle' : 'Right ankle',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(n.connected
                          ? 'connected  ${st ?? ''}${_synced[n.role] != null ? '  synced' : ''}'
                          : 'not connected'),
                    ],
                  ),
                ),
                Icon(n.connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                    color: n.connected ? Colors.green : Colors.grey),
              ],
            ),
            if (n.connected && (st?.boardMoved ?? false))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Board moved on the strap? Calibrate again.', style: TextStyle(color: Colors.orange)),
              ),
            if (n.connected) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(onPressed: () => _calibrate([n]), child: const Text('Calibrate')),
                  OutlinedButton(onPressed: () => _sync(n), child: const Text('Sync clock')),
                  OutlinedButton(onPressed: () => n.buzzTest(Haptic.double), child: const Text('Buzz')),
                  OutlinedButton.icon(
                    onPressed: _openLiveView,
                    icon: const Icon(Icons.threed_rotation, size: 18),
                    label: const Text('Live view'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
