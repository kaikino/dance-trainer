import 'package:flutter/material.dart';

import '../store/recording.dart';
import '../store/session_store.dart';
import '../ui/style.dart';
import 'recording_screen.dart';
import '../store/app_dirs.dart';
import 'package:flutter/foundation.dart';

/// Saved recordings on the device ([AppDirs.shared]), by training
/// session: open a run to see its data, or delete a run or a whole session.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  List<RecordingFolder>? _folders;
  Object? _error;
  String _root = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = await RecordingIndex.load();
      final root = await SessionRecorder.sharedRoot();
      if (mounted) {
        setState(() {
          _folders = f;
          _root = root;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(RunInfo r) async {
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => RecordingScreen(dir: r.dir)));
    await _load();
  }

  Future<void> _deleteRun(RunInfo r) async {
    if (!await confirmDelete(context, 'Delete this run?', '${r.preset}, ${_when(r)}. Its recording is removed from ${AppDirs.deviceName(MediaQuery.sizeOf(context))}.')) {
      return;
    }
    await r.dir.delete(recursive: true);
    await _load();
  }

  Future<void> _deleteFolder(RecordingFolder f) async {
    final n = f.runs.length;
    if (!await confirmDelete(context, 'Delete this ${f.training ? 'training session' : 'folder'}?',
        '${f.title}: $n run${n == 1 ? '' : 's'} removed from ${AppDirs.deviceName(MediaQuery.sizeOf(context))}.')) {
      return;
    }
    if (f.dir.path == _root) {
      for (final r in f.runs) {
        await r.dir.delete(recursive: true); // loose runs: only these, not the root
      }
    } else {
      await f.dir.delete(recursive: true);
    }
    await _load();
  }

  static String _when(RunInfo r) {
    final w = r.when;
    if (w == null) return r.id;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(w.hour)}:${two(w.minute)}:${two(w.second)}';
  }

  static String _size(int b) =>
      b > 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = _folders;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded), tooltip: 'Refresh')],
      ),
      body: _error != null
          ? Center(child: Text('Could not read the recordings: $_error'))
          : f == null
              ? const Center(child: CircularProgressIndicator())
              : f.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Space.xl),
                        child: Text(
                          'No recordings yet. Choose Capture on the routine screen: each recorded run is saved here.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(Space.gutter(context), Space.md, Space.gutter(context), Space.xl),
                      children: [
                        ContentWidth(
                          maxWidth: 900,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                  defaultTargetPlatform == TargetPlatform.iOS
                                      ? 'In ${AppDirs.sharedLabel} (Files app, or Finder over USB).'
                                      : 'In ${AppDirs.sharedLabel} on ${AppDirs.deviceName(MediaQuery.sizeOf(context))} (Files app, or over USB).',
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                              const SizedBox(height: Space.md),
                              for (var i = 0; i < f.length; i++) _folder(context, f[i], expanded: i == 0),
                            ],
                          ),
                        ),
                      ],
                    ),
    );
  }

  Widget _folder(BuildContext context, RecordingFolder f, {required bool expanded}) {
    final theme = Theme.of(context);
    final bytes = f.runs.fold<int>(0, (s, r) => s + r.bytes);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: Space.md),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        shape: const Border(),
        leading: Icon(f.training ? Icons.folder_special_rounded : Icons.folder_rounded, color: theme.colorScheme.primary),
        title: Text(f.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        subtitle: Text('${f.subtitle} · ${f.runs.length} run${f.runs.length == 1 ? '' : 's'} · ${_size(bytes)}'),
        trailing: IconButton(
          onPressed: () => _deleteFolder(f),
          icon: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
          tooltip: 'Delete the whole ${f.training ? 'training session' : 'folder'}',
        ),
        children: [
          if (f.runs.isEmpty)
            const ListTile(title: Text('No runs saved in this session.')),
          for (final r in f.runs)
            ListTile(
              contentPadding: const EdgeInsets.only(left: Space.xl, right: Space.sm),
              leading: const Icon(Icons.show_chart_rounded),
              title: Text(r.preset),
              subtitle: Text('${_when(r)} · ${r.steps} steps · ${_size(r.bytes)}${r.mode == 'capture' || r.mode.isEmpty ? '' : ' · ${r.mode}'}'),
              onTap: () => _open(r),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: () => _open(r),
                    icon: const Icon(Icons.insights_rounded),
                    label: const Text('View data'),
                  ),
                  IconButton(
                    onPressed: () => _deleteRun(r),
                    icon: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
                    tooltip: 'Delete this run',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
