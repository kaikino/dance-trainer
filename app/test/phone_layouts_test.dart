import 'dart:io';

import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/main.dart';
import 'package:dance_trainer/models/preset.dart';
import 'package:dance_trainer/ble/protocol.dart';
import 'package:dance_trainer/screens/calibrate_screen.dart';
import 'package:dance_trainer/screens/connect_screen.dart';
import 'package:dance_trainer/screens/dance_screen.dart';
import 'package:dance_trainer/screens/history_screen.dart';
import 'package:dance_trainer/screens/live_view_screen.dart';
import 'package:dance_trainer/screens/onboarding_screen.dart';
import 'package:dance_trainer/screens/preset_screen.dart';
import 'package:dance_trainer/screens/recording_screen.dart';
import 'package:dance_trainer/screens/recordings_screen.dart';
import 'package:dance_trainer/screens/summary_screen.dart';
import 'package:dance_trainer/store/app_dirs.dart';
import 'package:dance_trainer/models/session_score.dart';
import 'package:dance_trainer/store/session_store.dart';
import 'package:dance_trainer/ui/run_timeline.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'recording_test.dart' show fakeRun;
import 'support/fake_platforms.dart';
import 'support/fonts.dart';

/// A device: its screen in points (portrait) and its safe-area insets
/// (top, bottom in portrait; side, bottom in landscape).
class Device {
  const Device(this.name, this.w, this.h, this.top, this.bottom, this.side, this.landBottom, {this.dpr = 3});
  final String name;
  final double w, h, top, bottom, side, landBottom, dpr;
}

/// iPhones from the smallest to the largest screen, and an iPad.
const devices = [
  Device('iPhone SE', 375, 667, 20, 0, 0, 0, dpr: 2),
  Device('iPhone 13 mini', 375, 812, 50, 34, 50, 21),
  Device('iPhone 16', 393, 852, 59, 34, 59, 21),
  Device('iPhone 16 Pro Max', 440, 956, 62, 34, 62, 21),
  Device('iPad mini', 744, 1133, 24, 20, 0, 20, dpr: 2),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final docs = FakeDocuments();
  PathProviderPlatform.instance = docs;
  installFakeAudio();

  late NodeManager m;
  late Preset box;
  setUpAll(() async {
    await loadRealFonts();
    m = NodeManager(fake: true);
    box = await Preset.loadAsset('assets/presets/box_step.json');
  });

  /// Every screen, as iOS, at each device's size and insets, upright and on
  /// its side. A RenderFlex overflow (or any other error) fails the test.
  for (final d in devices) {
    for (final landscape in [false, true]) {
      final label = '${d.name} ${landscape ? 'landscape' : 'portrait'}';

      Future<void> show(WidgetTester t, Widget screen, {int settleMs = 600}) async {
        // Asset loads cached by an earlier test belong to its (finished) test zone.
        rootBundle.clear();
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final size = landscape ? Size(d.h, d.w) : Size(d.w, d.h);
        t.view.devicePixelRatio = d.dpr;
        t.view.physicalSize = size * d.dpr;
        t.view.padding = landscape
            ? FakeViewPadding(left: d.side * d.dpr, right: d.side * d.dpr, bottom: d.landBottom * d.dpr)
            : FakeViewPadding(top: d.top * d.dpr, bottom: d.bottom * d.dpr);
        // SF Pro runs a little wider than Roboto, and people enlarge text:
        // test at 110 %.
        t.platformDispatcher.textScaleFactorTestValue = 1.1;
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await t.pumpWidget(DanceTrainerApp(manager: m, home: screen));
        for (var ms = 0; ms < settleMs; ms += 100) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> done(WidgetTester t) async {
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 30)); // the simulated nodes' timers (calibration) run out
        debugDefaultTargetPlatformOverride = null; // must be back before the test ends
      }

      testWidgets('$label: home, nodes not connected', (t) async {
        await show(t, ConnectScreen(manager: NodeManager(fake: true)));
        await done(t);
      });

      testWidgets('$label: home, both nodes connected', (t) async {
        await t.runAsync(m.scanAndConnect);
        await show(t, ConnectScreen(manager: m));
        await done(t);
      });

      testWidgets('$label: how to wear', (t) async {
        await show(t, OnboardingScreen(manager: m));
        await done(t);
      });

      testWidgets('$label: calibrate', (t) async {
        await t.runAsync(m.scanAndConnect);
        await show(t, CalibrateScreen(manager: m, nodes: m.nodes));
        await done(t);
      });

      testWidgets('$label: choose a routine', (t) async {
        await t.runAsync(m.scanAndConnect);
        await show(t, PresetScreen(manager: m), settleMs: 1500);
        final list = find.byType(ListView);
        expect(list, findsOneWidget, reason: 'the routines loaded');
        await t.drag(list, const Offset(0, -600));
        await t.pump(const Duration(milliseconds: 300));
        await done(t);
      });

      testWidgets('$label: watch first (chart and floor map)', (t) async {
        await show(t, DanceScreen(manager: m, preset: box, kind: SessionKind.performance, dancer: 't', demo: true),
            settleMs: 1500);
        await done(t);
      });

      testWidgets('$label: dancing, nodes connected', (t) async {
        await t.runAsync(m.scanAndConnect);
        await show(t, DanceScreen(manager: m, preset: box, kind: SessionKind.performance, dancer: 't'), settleMs: 1500);
        await done(t);
      });

      testWidgets('$label: summary of a recording', (t) async {
        late SessionRecorder rec;
        await t.runAsync(() async {
          rec = SessionRecorder(preset: box, dancer: 't', mode: Mode.capture, nodes: m);
          await rec.begin();
          rec.addSegment(DateTime.now().millisecondsSinceEpoch);
          await rec.end();
        });
        await show(
            t,
            SummaryScreen(
                manager: m,
                preset: box,
                kind: SessionKind.capture,
                dancer: 't',
                recorder: rec,
                score: SessionScore(box)));
        await done(t);
      });

      for (final kind in [SessionKind.performance, SessionKind.practice]) {
        testWidgets('$label: summary of ${kind.name}, with its timeline', (t) async {
          late SessionRecorder rec;
          await t.runAsync(() async {
            rec = SessionRecorder(preset: box, dancer: 't', mode: Mode.dance, nodes: m);
            await rec.begin();
            rec.addSegment(DateTime.now().millisecondsSinceEpoch);
            await rec.end();
          });
          // A run with some of everything, so the timeline has dots, weak bars and (Practice) rewinds.
          final score = SessionScore(box);
          for (var i = 0; i < box.steps.length; i++) {
            final st = box.steps[i];
            final v = i % 7 == 3
                ? Verdict.offBeat
                : i % 9 == 5
                    ? Verdict.wrongStep
                    : i % 13 == 8
                        ? Verdict.missed
                        : Verdict.correct;
            score.add(st.foot, StepEvent(i + 1, 0, st.stepClass, 200, st.stepClass, (i % 5 - 2) * 70, v), st.beat);
          }
          if (kind == SessionKind.practice) score.rewindsByBar.addAll({3: 2, 7: 1});
          await show(t, SummaryScreen(manager: m, preset: box, kind: kind, dancer: 't', recorder: rec, score: score));
          await t.scrollUntilVisible(find.byKey(RunTimeline.chartKey), 200, scrollable: find.byType(Scrollable).first);
          await t.pump(const Duration(milliseconds: 300));
          await done(t);
        });
      }

      testWidgets('$label: history', (t) async {
        await show(t, HistoryScreen(preset: box));
        await done(t);
      });

      testWidgets('$label: live view', (t) async {
        await t.runAsync(m.scanAndConnect);
        await show(t, LiveViewScreen(manager: m));
        await done(t);
      });

      testWidgets('$label: recordings', (t) async {
        await t.runAsync(() async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          final root = Directory(await AppDirs.shared());
          final run = Directory('${root.path}/training-20261113-101500-kai/20261113-101500-kai');
          if (!run.existsSync()) {
            run.createSync(recursive: true);
            for (final f in fakeRun().listSync().whereType<File>()) {
              f.copySync('${run.path}/${f.uri.pathSegments.last}');
            }
          }
        });
        await show(t, const RecordingsScreen(), settleMs: 800);
        await done(t);
      });

      for (final stacked in [false, true]) {
        testWidgets('$label: recording data${stacked ? ', left above right' : ''}', (t) async {
          final dir = fakeRun();
          await show(t, RecordingScreen(dir: dir), settleMs: 1200);
          if (stacked) {
            final sw = find.byType(Switch);
            if (sw.evaluate().isNotEmpty) {
              await t.ensureVisible(sw.first);
              await t.tap(sw.first);
              await t.pump(const Duration(milliseconds: 300));
              await t.tap(sw.first); // back, so the next test starts side by side
              await t.pump(const Duration(milliseconds: 300));
            }
          }
          await done(t);
        });
      }
    }
  }

  test('iOS keeps saved runs in the app\'s Documents folder (Files app), the rest in Application Support', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      expect(await AppDirs.shared(), '${docs.root.path}/DanceTrainer');
      expect((await AppDirs.private()).path, docs.supportPath);
      expect(AppDirs.describe('${docs.root.path}/DanceTrainer/training-x/run'),
          'Files › On My iPhone › Dance Trainer › DanceTrainer/training-x/run');
      expect(AppDirs.deviceName(const Size(393, 852)), 'this iPhone');
      expect(AppDirs.deviceName(const Size(744, 1133)), 'this iPad');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
