# Ankle node firmware (Seeed XIAO nRF52840 Sense Plus)

Arduino framework on the Adafruit nRF52 core (Seeed's board package), built with
`arduino-cli`. No IDE needed. The ESP-IDF version of this firmware is at git tag
`esp-idf-last` if the team falls back to the ESP32-S3 boards.

## Build and flash

```
make setup                       # once: arduino-cli core for Seeeduino:nrf52
make                             # left node, CNN classifier → build/L-cnn/
make ROLE=R                      # right node
make flash PORT=/dev/cu.usbmodem1101 ROLE=R
make monitor PORT=/dev/cu.usbmodem1101
```

`make flash` uses the serial DFU bootloader the XIAO ships with. If the board is
not enumerating, double-tap its reset button: a `XIAO-SENSE` drive appears and
`build/<variant>/dance_node.ino.uf2` can be dropped on it instead.

The compile-time role is only a default. Over the serial console, `role L` or
`role R` stores the role in flash and reboots, so one build serves both nodes.

## Serial console (115200)

| Command | Does |
| --- | --- |
| `status` | role, mode, battery, BLE state, calibration, node clock |
| `cal` | 2 s still-pose calibration (same as the app's Calibrate) |
| `buzz [1\|2\|3]` | short / double / long motor pattern |
| `selftest` | runs the CNN on 20 embedded windows, prints `idx,class,conf,us` |
| `role L\|R` | store role and reboot |

`selftest` output must match `ml/export.py --selftest` on class and within ±2 on conf.

## Tasks

Single core, FreeRTOS priorities 0–4 (Bluefruit's own task runs at 3).

| Task | Prio | Trigger | Reads → writes |
| --- | --- | --- | --- |
| `imu_task` | 4 | LSM6DS3TR-C INT1 data-ready, 104 Hz | I2C → `sample_q` |
| `fusion_task` | 3 | `sample_q` | Madgwick → ring buffer |
| `detect_task` | 2 | ring buffer, per strike | → `window_q` |
| `infer_judge_task` | 2 | `window_q` | CNN → judge → `haptic_q`, `event_q` |
| `haptic_task` | 2 | `haptic_q` | motor GPIO patterns |
| `ble_evt`, `ble_stream`, `ble_status` | 2 / 2 / 1 | `event_q`, ring, 2 s tick | notifications |
| `loop()` | 1 | serial | console |

While the motor runs (plus 120 ms of settling), `detect_task` refuses to start a
strike candidate, so the node's own buzz cannot be mistaken for a step.

## Sources (`dance_node/src/`)

- `dt_protocol.h` — wire structs and enums. Mirrors `docs/ble-protocol.md`.
- `board.h` — pin names for the XIAO; `dt_port.h` / `port.cpp` — µs clock (TIMER4), logging, flash blob storage (LittleFS), stored role.
- `imu.cpp` — onboard LSM6DS3TR-C over `Wire1`, 104 Hz, ±16 g, ±2000 dps, INT1 data-ready.
- `fusion.c`, `madgwick.c` — 6-axis AHRS, gravity alignment and gyro bias from calibration.
- `stepdet.c` — foot-strike detector and 60×9 int8 window cutter; `rules.c` — rule classifier.
- `cnn.c` — float inference for the `ml/train.py` network; `model_weights.h` and `selftest_vectors.h` are written by `ml/export.py`.
- `model.c` — classifier dispatch (`-DDT_CLASSIFIER_RULES` selects the rules) and `selftest`.
- `judge.c` — schedule matching and verdicts; missed-step tick.
- `haptic.cpp` — Grove Vibration Motor patterns on one GPIO, plus the blanking window.
- `ble.cpp` — Bluefruit GATT service, advertising as `DT-L` / `DT-R`, 15 ms connection interval, MTU 247.
- `timesync.c` — answers time-sync writes; `power.cpp` — battery voltage through the XIAO's divider.
- `app.cpp` — queues, task start-up, serial console.

## Pins

| Signal | XIAO pin | nRF52840 |
| --- | --- | --- |
| Vibration motor SIG | D0 | P0.02 |
| IMU SDA / SCL (internal) | — | P0.07 / P0.27 |
| IMU INT1 (internal) | — | P0.11 |
| IMU power (internal) | — | P1.08 |
| Battery sense / enable (internal) | — | P0.31 / P0.14 |
| Charge current select (internal) | — | P0.13 |

Everything but the motor is on the board already. Names come from the board
package's `variant.h` via `src/board.h`.

## Known gaps

- Time base is TIMER4, which keeps the 16 MHz clock running. Moving it to RTC2
  would cut idle current; do this after the first battery-life measurement.
- No light sleep when idle and disconnected.
- Rules and CNN thresholds are from synthetic data until real captures exist.
