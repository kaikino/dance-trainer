# Developer guide

How to get from a fresh clone to two working ankle nodes and the app on a
tablet or phone, and how to update each part afterwards. Commands are for
macOS (Homebrew); Linux is the same apart from the install lines and port names.

## What is what

```
firmware/   ankle node firmware (Seeed XIAO nRF52840 Sense Plus, Arduino + arduino-cli)
app/        Flutter app: Android tablet/phone, iPhone, iPad
ml/         Python: simulators, rule/CNN evaluation, training, export to firmware
presets/    routines (JSON); the app bundles them (app/assets/presets is a link)
docs/       protocol, data format, preset format, bench check, iOS setup
hardware/   BOM and wiring
```

Two nodes, **L** and **R**, each strap to an ankle. They detect and classify
every step on the board and talk Bluetooth LE to the app, which plays the
music, draws the step chart and floor map, and shows verdicts. The wire format
is `docs/ble-protocol.md`; it is mirrored in three places that must agree:
`firmware/dance_node/src/dt_protocol.h`, `app/lib/ble/protocol.dart`,
`ml/dt/protocol.py` (tests check it).

## 1. One-time setup

| You work on | Install |
| --- | --- |
| Firmware | `brew install arduino-cli`, then `cd firmware && make setup` (board package `Seeeduino:nrf52`) |
| App, Android | [Flutter](https://docs.flutter.dev/get-started/install) (stable; Dart ≥ 3.4) and Android Studio *or* `brew install --cask android-commandlinetools` + `flutter doctor --android-licenses` |
| App, iOS | Xcode from the App Store and CocoaPods: see `docs/ios.md` |
| ML / tests | Python **3.12** (TensorFlow does not support 3.13 yet): `cd ml && python3.12 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt` |

Check with `flutter doctor` and `arduino-cli core list` (should list `Seeeduino:nrf52`).

## 2. Firmware: build and flash a node

Plug the XIAO in with a USB-C **data** cable and find its port:

```sh
ls /dev/cu.usbmodem*          # macOS; on Linux /dev/ttyACM*
```

Then, from `firmware/`:

```sh
make flash ROLE=L PORT=/dev/cu.usbmodem101      # left node
make flash ROLE=R PORT=/dev/cu.usbmodem101      # right node (plug it in instead)
make flash ROLE=X PORT=/dev/cu.usbmodem101      # spare: Bluetooth off, the app never connects to it
```

| Option | Default | Meaning |
| --- | --- | --- |
| `ROLE=L\|R\|X` | `L` | which ankle (advertises as `DT-L` / `DT-R`); `X` = spare/backup board |
| `CLASSIFIER=rules\|cnn` | `rules` | step classifier; the CNN is trained on simulated data only, so keep `rules` |
| `RULESDBG=1` | off | print the rule's measurements for every step from boot |

`make` alone only builds (into `build/<ROLE>-<CLASSIFIER>/`).

**Check it.** `make monitor PORT=…` opens the serial console (115200 baud).
Type `status`:

```
role=L mode=0 battery=3994 mV (78%) ble=advertising calibrated=1 forward=1 moved=0 …
```

Useful commands: `status`, `cal` (calibrate: stand still, then three forward
slides of the foot), `buzz 3` (motor test), `rulesdbg on` (one line per step),
`role L|R|X` (re-assign this board without reflashing; reboots), `help`. Full
list: `firmware/README.md`.

**If flashing fails** (no port, or the upload times out): double-tap the
board's reset button. A `XIAO-SENSE` drive appears; drag
`build/<ROLE>-rules/dance_node.ino.uf2` onto it.

**After flashing a new board**, calibrate it once while worn (the app's
Calibrate button, or `cal` on the console). The calibration is stored on the
board and survives power-off and reflashing.

## 3. App on an Android tablet or phone

One time on the device: Settings › About › tap *Build number* 7 times, then
Developer options › **USB debugging** on. Plug it in and accept the prompt.

```sh
cd app
flutter pub get
flutter devices                         # the tablet should be listed
flutter run --release                   # build, install and start
```

Or build an APK and install it with adb (also how you hand the app to someone):

```sh
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

(`adb` is in `…/platform-tools/`; with Homebrew's command-line tools:
`/opt/homebrew/share/android-commandlinetools/platform-tools/adb`.)

**Signing.** Release builds are signed with each developer's *debug* key. If
the tablet already has a build from another developer's machine, `adb install
-r` fails with *INSTALL_FAILED_UPDATE_INCOMPATIBLE*: uninstall first
(`adb uninstall com.example.dance_trainer`). That deletes the app's own data
(history, unsaved runs); runs kept with Save / training sessions are in
`Documents/DanceTrainer` and survive.

**No boards nearby?** Build with simulated nodes; everything works except real
sensing:

```sh
flutter run --release --dart-define=FAKE_NODES=true
```

## 4. App on an iPhone or iPad

Short version (details, signing and where files end up: `docs/ios.md`):

```sh
cd app
open ios/Runner.xcworkspace     # once: Runner › Signing & Capabilities › pick your Team, unique Bundle ID
flutter run --release -d <iphone>
```

The iOS Simulator has no Bluetooth; use `--dart-define=FAKE_NODES=true` there.

## 5. Using it (first run)

1. Switch both nodes on (they advertise as soon as they boot).
2. App › **Scan for nodes**. Allow Bluetooth when asked.
3. **Calibrate both feet**: stand still with feet under the hips, then three
   slides forward per foot when it buzzes. Each card should say *Calibrated*.
4. **Choose a routine** › Start (or **Watch first**, which needs no nodes).
5. To record training data: Advanced › **Capture**. That opens a *training
   session*; every recorded run is saved into it automatically (Discard on the
   summary to drop a bad one). Browse and graph them in **Recordings**.

## 6. Updating

```sh
git pull
cd app && flutter pub get && flutter run --release            # app
cd firmware && make flash ROLE=L PORT=…                       # each node whose firmware changed
```

The app and firmware share the protocol: after a protocol or step-class change
(see `git log -- docs/ble-protocol.md`), update **both** nodes and the app
together. The app only notices very old firmware (a missing Bluetooth
characteristic: "old or different firmware"); a node one change behind still
connects but may not know the newer step types, so when in doubt, reflash both.

## 7. Getting recordings off a device

| Device | Where | How |
| --- | --- | --- |
| Android | `Documents/DanceTrainer/training-<date>-<dancer>/<run>/` | Files app, USB file transfer, or `adb pull /sdcard/Documents/DanceTrainer` |
| iPhone/iPad | Files › On My iPhone › Dance Trainer › DanceTrainer | Files app, or Finder › the device › Files |

Each run folder has `session.json`, `L.csv`, `R.csv`, `events.csv`
(`docs/data-format.md`). Copy them to `ml/data/` for the ML scripts.

## 8. ML pipeline (optional)

From `ml/` with the venv active (full table of scripts: `ml/README.md`):

```sh
python -m pytest tests/                 # firmware/Python parity: rules, detector, judge, CNN
python realsim.py                       # rule + detector on both simulators (dev seed)
python realsim.py --seed 2              # held-out seed: report this one
python label.py data/*                  # label real recordings
python windows.py data/* -o runs/windows.npz && python train.py runs/windows.npz
python export.py runs/model.keras runs/windows.npz   # writes firmware weights
```

Then `make flash CLASSIFIER=cnn …` to try the CNN on a node; keep `rules`
unless the CNN beats it on data it was not trained on.

## 9. Before you commit

| Changed | Run |
| --- | --- |
| Anything in `app/` | `cd app && flutter analyze && flutter test` (includes every screen at iPhone/iPad sizes) |
| Firmware classifier / detector / judge | `cd ml && python -m pytest tests/` (compiles the C on the host and compares with Python) and `cd firmware && make` |
| Protocol or step classes | all of the above; the three protocol files must agree |
| A preset | `cd app && flutter test test/preset_test.dart test/floor_plan_test.dart` (danceable, returns to its start) |

Before a hand-off, also check that the release build compiles
(`flutter build apk --release`, and `flutter build ios` on a Mac with Xcode).

## 10. Troubleshooting

| Symptom | Fix |
| --- | --- |
| No `/dev/cu.usbmodem*` | Charge-only cable, or the board is asleep: try another cable, double-tap reset |
| `make flash` times out | Double-tap reset and drag the `.uf2` onto `XIAO-SENSE` |
| App finds no nodes | Node off or flat (`status` battery), already connected to another phone, or flashed as spare (`role=X`): `role L` / `role R` on the console |
| "… says it is the right node; expected DT-L" | The board's stored role is wrong: `role L` on its console |
| "old or different firmware", or new step types judged wrong | Flash the current firmware to that node |
| Every step "missed" | Not calibrated, or calibrated in a different pose than worn: recalibrate while wearing it |
| Steps detected but wrong type | Check `rulesdbg on` lines against `docs/bench-check.md` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Installed by another developer's build: uninstall first (section 3) |
| Recording not in Documents | The summary says why; older Android (< 11) cannot write there without a permission |
| TensorFlow will not install | Use Python 3.12 for the venv |
