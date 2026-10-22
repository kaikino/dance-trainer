import 'package:flutter/material.dart';

import 'ble/node_client.dart';
import 'chart/step_chart.dart';
import 'models/preset.dart';

void main() => runApp(const DanceTrainerApp());

class DanceTrainerApp extends StatelessWidget {
  const DanceTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dance Trainer',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ConnectScreen(),
    );
  }
}

/// Week 1–2 target: scan, show DT-L / DT-R, read Status.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final manager = NodeManager();

  @override
  void initState() {
    super.initState();
    manager.addListener(() => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dance Trainer')),
      body: Column(
        children: [
          for (final node in manager.nodes)
            ListTile(
              leading: Text(node.roleLabel, style: const TextStyle(fontSize: 24)),
              title: Text(node.name),
              subtitle: Text(node.status?.toString() ?? 'not connected'),
              trailing: node.connected
                  ? const Icon(Icons.bluetooth_connected)
                  : const Icon(Icons.bluetooth_disabled),
            ),
          const Divider(),
          Expanded(
            child: FutureBuilder<Preset>(
              future: Preset.loadAsset('presets/box_step.json'),
              builder: (context, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                // Static preview: beat 1 at t=0, "now" at beat 2.5.
                return StepChart(preset: snap.data!, nowBeat: 2.5, verdicts: const {});
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: manager.scanAndConnect,
        icon: const Icon(Icons.search),
        label: const Text('Scan'),
      ),
    );
  }
}
