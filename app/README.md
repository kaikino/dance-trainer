# Dance Trainer app (Flutter)

## First-time setup

```
flutter pub get
flutter analyze && flutter test
flutter run            # on a real phone; BLE does not work in simulators
```

Platform folders are committed. BLE permissions are already in
`ios/Runner/Info.plist` and `android/app/src/main/AndroidManifest.xml`.

## Layout

```
lib/
├── main.dart                 app entry
├── ble/
│   ├── protocol.dart         wire structs + enums (mirror of docs/ble-protocol.md)
│   └── node_client.dart      one NodeClient per ankle; NodeManager holds both
├── models/preset.dart        presets/*.json → Preset, and → per-node schedule bytes
├── audio/beat_clock.dart     music or generated metronome; beat clock from player position
├── store/session_store.dart  records a session folder in docs/data-format.md layout
├── chart/step_chart.dart     two-lane scrolling footprint chart
└── screens/
    ├── connect_screen.dart   scan, calibrate (still + slide), sync clock, buzz test
    ├── preset_screen.dart    routine, tempo, Capture / Performance / Practice, dancer name
    ├── dance_screen.dart     count-in, music, live chart with verdicts; Practice pause+rewind
    └── summary_screen.dart   accuracy, timing, errors by foot and step; export files
```

Session flow: Connect → Routine → Dance → Summary. On Dance entry the app
pushes the schedule to each node, starts the music, measures when playback
actually began, and sends Start(t0) so beat 1 is the same instant on the phone
and both nodes. Capture mode records 100 Hz from both nodes plus every step
event, labelled from the schedule, into the app's documents folder under
`sessions/<id>/`; the Summary screen's Export shares those four files.

## Big screen

`flutter run -d chrome` (or `-d macos`) with `--dart-define=CAST_CLIENT=1` runs the
step chart alone and connects to the phone over a WebSocket on port 8765. The
phone serves the chart state (`now`, `preset_id`, verdicts). Week 9 task.
Until then, AirPlay / Chromecast the phone screen.

## Screens (week by week)

| Week | Screen |
| --- | --- |
| 1–2 | Connect: scan, assign L/R from Status, battery |
| 3 | Time sync + calibrate buttons; session store; export |
| 4 | Presets; music + beat clock; Capture mode |
| 5 | Dance: step chart, live verdicts |
| 6 | Casting + delay calibration; Performance score |
| 7 | Practice mode; session summary |
| 8 | Replay |
