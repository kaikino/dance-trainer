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
  "preset_name": "Box step",
  "bpm": 100,
  "mode": "capture",
  "t0_app_ms": 1760985000123,
  "nodes": {
    "L": {"offset_us": 123456789, "fw_version": 258},
    "R": {"offset_us": 987654321, "fw_version": 258}
  },
  "app_version": "0.1.0",
  "protocol_version": 1
}
```

`offset_us` converts node time to app time: `t_app_us = t_node_us − offset_us`.

## L.csv / R.csv (100 Hz in capture mode, 50 Hz in dance mode)

```
t_node_us,ax,ay,az,gx,gy,gz,qw,qx,qy,qz
```

- `ax..az` sensor-frame, mg. `gx..gz` dps × 10. Empty in dance mode.
- `qw..qz` × 1/16384.

## events.csv

```
t_strike_node_us,foot,step_class,confidence,expected_class,timing_err_ms,verdict,label_class,label_source
```

- `step_class..verdict` as the node sent them.
- `label_class` is the training label: in capture mode the app fills it with the
  preset's expected class at the nearest beat (`label_source = capture`);
  a human can overwrite it from video (`label_source = manual`); `-1` = unusable.
