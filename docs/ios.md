# Running the app on an iPhone or iPad

The app is one Flutter code base; on iOS it behaves as on Android (same
screens, nodes, judging, recordings). What differs is listed at the end.

## One-time setup (Mac)

1. Install **Xcode** from the App Store, open it once, then:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   brew install cocoapods        # plugins that are not Swift packages yet
   flutter doctor                # the Xcode line should be green
   ```
2. Open `app/ios/Runner.xcworkspace` in Xcode, select the **Runner** target,
   **Signing & Capabilities**: choose your Team (a free Apple ID works for
   your own phone) and change the Bundle Identifier from
   `com.example.danceTrainer` to something unique, e.g. `edu.<you>.dancetrainer`.
3. On the iPhone: Settings › Privacy & Security › **Developer Mode** on
   (it asks after the first install from Xcode).

## Build and run

```sh
cd app
flutter run -d <iphone>                       # USB or Wi-Fi; `flutter devices` lists it
flutter run --release -d <iphone>             # the build to dance with (debug is slower)
flutter build ipa                             # for TestFlight / sharing with the team
```

The iOS **Simulator has no Bluetooth**: use the simulated nodes there.

```sh
flutter run -d "iPhone 16" --dart-define=FAKE_NODES=true
```

With a free Apple ID the app stops opening after 7 days; run it from Xcode or
`flutter run` again to re-sign it.

## First launch

- Scanning asks **"Dance Trainer would like to use Bluetooth"**: allow it. If
  it was denied: Settings › Privacy & Security › Bluetooth › Dance Trainer.
- The screen stays on while a routine runs (as on Android), so the phone does
  not lock mid-dance.
- Music and clicks play with the ring/silent switch on silent.

## Where recordings are

| | Android | iOS |
| --- | --- | --- |
| Kept runs (Save, training sessions) | `Documents/DanceTrainer` on shared storage | Files › On My iPhone › Dance Trainer › `DanceTrainer` (and Finder › the iPhone › Files over USB) |
| Every run as recorded, history, settings | the app's own folder | the app's own folder (Application Support; not shown in Files) |
| Survives reinstalling the app | yes | no: deleting the app deletes its recordings, so copy them off first |

The folder layout inside is the same (`training-…/<run>/session.json, L.csv,
R.csv, events.csv`, docs/data-format.md), so `ml/` reads either.

## Screen sizes

Every screen is checked by `app/test/phone_layouts_test.dart` as iOS on the
iPhone SE, 13 mini, 16 and 16 Pro Max and an iPad mini, upright and on its
side, with the notch / Dynamic Island and home-indicator insets and text at
110 %. On a phone:

- the dance screen puts the floor map above the step chart (upright) or
  beside it (on its side);
- the recording viewer scrolls through full-width charts (left above right
  when upright), with the summary and controls in one sideways-scrolling row;
- the routine screen's Watch first button is an eye icon.

## What differs from Android, and why

- **No "Turn on Bluetooth" button**: iOS does not let apps switch Bluetooth
  on; the message says where to do it.
- **Packet size**: iOS picks the Bluetooth packet size itself (Android asks
  for 247 bytes). The nodes send at most 74 bytes per notification and ask
  for a 15–30 ms connection interval, both within what iPhones accept, so no
  firmware change is needed.
- **Back gesture and scrolling** follow iOS (swipe from the left edge,
  bounce); the dance screen still asks before ending a session.
