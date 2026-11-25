import 'package:dance_trainer/ble/node_client.dart';
import 'package:dance_trainer/main.dart';
import 'package:dance_trainer/screens/preset_screen.dart';
import 'package:dance_trainer/store/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

/// The routine screen's preview music plays only while that screen is in
/// front. A run ends by replacing the dance screen with its summary, and Try
/// again replaces the summary with a new dance screen: the routine screen is
/// covered the whole time, so its music must stay off until it is back in front.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = FakeDocuments();
  installFakeAudio();

  testWidgets('preview stays off while runs replace each other on top, and comes back after', (t) async {
    AppSettings.musicPreview = true;
    rootBundle.clear();
    final m = NodeManager(fake: true);
    await t.pumpWidget(DanceTrainerApp(manager: m, home: PresetScreen(manager: m)));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 100));
    }
    dynamic screen() => t.state(find.byType(PresetScreen, skipOffstage: false));
    expect(screen().previewing, isNotNull, reason: 'the routine in the middle plays');

    final nav = t.state<NavigatorState>(find.byType(Navigator));
    Route<void> page(String name) => MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(name)));
    nav.push(page('dance'));                                   // Start
    await t.pumpAndSettle();
    expect(screen().previewing, isNull, reason: 'silent while dancing');

    nav.pushReplacement(page('summary'));                      // the run ends
    await t.pumpAndSettle();
    expect(screen().previewing, isNull, reason: 'still covered: no music behind the summary');

    nav.pushReplacement(page('dance again'));                  // Try again
    await t.pumpAndSettle();
    expect(screen().previewing, isNull, reason: 'no music under the next run');

    nav.pop();                                                 // back to the routine screen
    await t.pump(const Duration(milliseconds: 600));           // (its floor map keeps animating: no settle)
    expect(screen().previewing, isNotNull, reason: 'in front again: the preview is back');

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });
}
