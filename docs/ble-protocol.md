# BLE protocol

Source of truth for the node ⇄ phone interface. Firmware (`components/ble`,
`components/common/include/dt_protocol.h`) and app (`app/lib/ble/protocol.dart`)
implement exactly this. Bump `PROTOCOL_VERSION` on any wire change.

- Role: node = GATT peripheral, phone = central. One connection per node.
- MTU: request 247. Connection interval: request 15 ms (7.5–30 ms acceptable).
- All multi-byte integers little-endian. Structs are packed (no padding).
- Node clock `t_node_us`: `esp_timer_get_time()`, u32 wraps every ~71 min
  (sessions are shorter; app handles one wrap).

## UUIDs

Base: `7d4e XXXX-5a1c-4b8e-9f3a-2c6d8e1f0a00`

| XXXX | Name | Properties |
| --- | --- | --- |
| 0001 | Dance Trainer service | — |
| 0002 | Status | read, notify |
| 0003 | Time sync | write, notify |
| 0004 | Schedule | write |
| 0005 | Control | write |
| 0006 | Step event | notify |
| 0007 | Stream | notify |

Advertised name: `DT-L` or `DT-R` by role.

## Enums

```
step_class: 0 none, 1 in_place, 2 forward, 3 back, 4 side_out, 5 cross, 6 kick
verdict:    0 unjudged, 1 correct, 2 off_beat, 3 wrong_step, 4 missed, 5 extra
mode:       0 idle, 1 capture, 2 dance
role:       0 left, 1 right
haptic:     1 short (timing error), 2 double (wrong step), 3 long (test)
```

## Status (0002) — 6 bytes

| field | type | notes |
| --- | --- | --- |
| protocol_version | u8 | currently 1 |
| role | u8 | |
| fw_version | u16 | major<<8 \| minor |
| battery_pct | u8 | 0–100 |
| mode | u8 | |

Notified on change.

## Time sync (0003)

Phone writes 4 bytes: `t_app_ms u32`.
Node notifies 8 bytes immediately: `t_app_ms u32, t_node_us u32`.

Phone computes `offset = t_node_us − (t_app_ms_send + rtt/2) × 1000`. Repeat 8×,
keep the sample with the smallest round trip. Re-sync every 10 s while dancing.

## Schedule (0004) — chunked write

Phone writes one or more chunks. First byte of every chunk is `flags`:
bit 0 = header chunk, bit 1 = last chunk.

Header chunk (7 bytes):

| field | type |
| --- | --- |
| flags | u8 (bit0 set) |
| preset_id | u16 |
| bpm_x10 | u16 |
| n_steps | u16 |

Step chunk: `flags u8`, then N × 3 bytes `(beat_x100 u16, step_class u8)` for
the steps meant for *this* node (the app filters by foot). Max 80 steps per chunk.
Node replaces its schedule when the header arrives and acknowledges nothing;
app reads Status.mode to confirm it is idle before writing.

## Control (0005)

| cmd | args | meaning |
| --- | --- | --- |
| 1 start | `mode u8, t0_node_us u32` | beat 1 is at `t0_node_us`; mode 1 capture or 2 dance |
| 2 stop | — | back to idle |
| 3 calibrate | — | 2 s still pose; stores gravity alignment + gyro bias in NVS |
| 4 buzz_test | `pattern u8` | fires a haptic pattern |
| 5 set_threshold | `conf u8` | min confidence (0–255) to buzz; default 160 |
| 6 set_window | `ms u16` | timing tolerance ± ms; default 150 |
| 7 selftest | — | runs the model on stored windows, prints to serial |

## Step event (0006) — 12 bytes, notify

| field | type | notes |
| --- | --- | --- |
| seq | u16 | per-session counter |
| t_strike_node_us | u32 | foot-strike time |
| step_class | u8 | model output |
| confidence | u8 | 0–255 |
| expected_class | u8 | 0 if none scheduled |
| timing_err_ms | i16 | strike − expected; 0 if none scheduled |
| verdict | u8 | 0 in capture mode |

Missed steps are sent with `step_class = 0`, `t_strike_node_us` = expected time.

## Stream (0007) — 74 bytes, notify every 100 ms

| field | type |
| --- | --- |
| t0_node_us | u32 |
| 5 × sample | 14 bytes each |

Sample: `qw, qx, qy, qz i16` (×1/16384), `ax, ay, az i16` (mg).

In idle and dance mode: samples 20 ms apart (50 Hz); `ax..az` are in the
**foot frame**: leveled, yaw removed so +x = toe direction, gravity removed, and
y mirrored on the left node so +y = outward on both feet.

In capture mode the node streams 100 Hz instead: `ax..az` are in the **aligned
sensor frame** (after the calibration rotation, gravity included), and a second
notify per batch carries `gx, gy, gz` (dps × 10) in the `ax..az` slots with
`qw = 0x7FFF` marking it as a gyro packet. The app stores both; `ml/` rebuilds
the foot frame from them with the same math as the firmware.

## Frames

| Frame | Definition | Where |
| --- | --- | --- |
| raw sensor | IMU axes as mounted | inside `imu` only |
| aligned sensor | raw rotated so gravity at the calibration pose is +z | capture stream, model channels 0–5 |
| world | aligned sensor rotated by the Madgwick quaternion | intermediate |
| foot | world with yaw removed (+x = toe), gravity removed, y mirrored for L | dance stream, model channels 6–8, rule classifier |
