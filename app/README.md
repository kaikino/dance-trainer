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
├── main.dart              app entry, route table
├── ble/
│   ├── protocol.dart      wire structs + enums (mirror of docs/ble-protocol.md)
│   └── node_client.dart   one NodeClient per ankle; NodeManager holds both
├── models/
│   └── preset.dart        presets/*.json → Preset, and → per-node schedule bytes
├── chart/
│   └── step_chart.dart    CustomPainter: two lanes, footprints scrolling to "now"
└── (to add) screens/, store/, replay/, cast/
```

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
