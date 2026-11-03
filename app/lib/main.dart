import 'package:flutter/material.dart';

import 'ble/node_client.dart';
import 'screens/connect_screen.dart';

void main() => runApp(DanceTrainerApp(manager: NodeManager()));

class DanceTrainerApp extends StatelessWidget {
  const DanceTrainerApp({super.key, required this.manager});
  final NodeManager manager;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dance Trainer',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: ConnectScreen(manager: manager),
    );
  }
}
