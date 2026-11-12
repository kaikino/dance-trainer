# Recorded-data format

The app exports one folder per session. `ml/` reads it unchanged.

```
ml/data/<session_id>/
├── session.json
├── L.csv
├── R.csv
└── events.csv
```

`session_id` = `YYYYMMDD-HHMMSS-<dancer>`.

## session.json

```json
{
  "session_id": "20261020-183000-kai",
  "dancer": "kai",
  "preset_id": 1,
  "preset_name": "Basic forward and back",
  "bpm": 100,
  "mode": "capture",
  "t0_app_ms": 1760985000123,
  "segments": [
    {"from_beat": 1.0, "t0_app_ms": 1760985000123, "bpm": 100},
    {"from_beat": 9.0, "t0_app_ms": 1760985012456, "bpm": 80}
  ],
  "nodes": {
    "L": {"offset_us": 123456789, "fw_version": 258},
    "R": {"offset_us": 987654321, "fw_version": 258}
  },
  "clock_syncs": [
    {"foot": "L", "offset_us": 123456789, "fw_version": 258, "synced_at_app_ms": 1760984998000},
    {"foot": "R", "offset_us": 987654321, "fw_version": 258, "synced_at_app_ms": 1760984998100}
  ],
  "app_version": "0.1.0",
  "protocol_version": 1,
  "score": {
    "kind": "performance",
    "complete": true,
    "judged": 32,
    "steps": 32,
    "accuracy": 0.875,
    "first_try_accuracy": 0.875,
    "bpm_min": 100,
    "bpm_max": 100,
    "ended_at_ms": 1760985031000
  }
}
```

`offset_us` converts node time to app time: `t_app_us = t_node_us − offset_us`.
`nodes` holds the last offset per node; `clock_syncs` lists every sync in order
(a reconnect, possibly after a node reboot that restarted its clock, adds one).
Node times are u32 µs and wrap every ~71.6 min; take differences modulo 2^32.
Prefer the per-row `t_app_ms` columns below; `ml/` falls back to node times
(unwrapped) and the offsets for sessions without them.

`segments`: one per start of the nodes (practice rewind, slow-down, resume).
`t0_app_ms` is the app time of (virtual) beat 1 at that segment's `bpm`, so beat
`b` is at `t0_app_ms + (b − 1) × 60000 / bpm`; the segment plays from `from_beat`.
`ml/label.py` matches a strike against the last segment started before it.
`t0_app_ms` (top level) is the first segment's; it is `null` and `segments` is
empty only for a session that never started (older app versions could save
one; the app now deletes it). `ml/` skips such a session with a message.

`score`: scored sessions only (Performance and Practice; Capture has none). The
History screen reads it back.

| Field | Meaning |
| --- | --- |
| `kind` | `performance` or `practice` |
| `complete` | danced from beat 1 to the end; false when ended early, drilled from a later bar, or a Practice bar was skipped with Keep going |
| `judged` | steps with a verdict (correct or a mistake) |
| `steps` | scheduled steps in the routine |
| `accuracy` | share of judged steps whose latest verdict is correct; `null` with none judged |
| `first_try_accuracy` | the same over each step's first attempt (before a rewind replayed it); `null` with none |
| `bpm_min`, `bpm_max` | slowest and fastest segment tempo (Practice may slow down) |
| `ended_at_ms` | app time the session ended |

## L.csv / R.csv (104 Hz in capture mode, 52 Hz in dance mode)

```
t_node_us,ax,ay,az,gx,gy,gz,qw,qx,qy,qz,t_app_ms
```

- Rows are 1e6/104 µs apart in capture mode, 1e6/52 µs otherwise (`t_node_us`
  is the batch t0 plus that spacing, u32).
- `t_app_ms`: app time of the row (0.1 ms), from the node's offset at the time.
- `ax..az` mg, in the frame the node streams (docs/ble-protocol.md): the
  calibrated **sensor frame** (gravity included) in capture mode, the **foot
  frame** (leveled, gravity removed, y mirrored on the right node) in dance
  mode. `gx..gz` dps × 10, empty in dance mode. In capture mode a row is
  written only when its accel and gyro batches pair up, so no cell is empty
  (older exports could have empty gyro cells; `ml/` skips those windows).
- `qw..qz` integers, × 1/16384 for the unit quaternion.

## events.csv

```
t_strike_node_us,foot,step_class,confidence,expected_class,timing_err_ms,verdict,label_class,label_source,t_app_ms
```

- `t_app_ms`: app time of the strike (rows sorted by it); empty if the node was
  not synced. `ml/` uses it to label and to find the strike in L/R.csv.

- `step_class..verdict` as the node sent them.
- `label_class` is the training label: in capture mode the app fills it with the
  preset's expected class at the nearest beat (`label_source = capture`);
  a human can overwrite it from video (`label_source = manual`); `-1` = unusable.
  `ml/label.py` keeps an app label that matches its segment-aware schedule match
  and sets one that disagrees to `-1` with `label_source = conflict`. Rows with
  `verdict = missed` or `step_class = 0`, and sessions with `mode` other than
  `capture`, are not used for training.
