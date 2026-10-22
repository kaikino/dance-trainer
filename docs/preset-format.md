# Preset format

`presets/<name>.json`. One file per choreography. The app loads it to draw the
step chart and to build the per-node schedule (see `docs/ble-protocol.md`).

```json
{
  "id": 1,
  "name": "Box step",
  "bpm": 100,
  "count_in_beats": 4,
  "loop": true,
  "repeats": 8,
  "steps": [
    {"beat": 1.0, "foot": "L", "class": "forward"},
    {"beat": 2.0, "foot": "R", "class": "side_out"}
  ]
}
```

| field | meaning |
| --- | --- |
| `id` | u16, unique across presets; goes on the wire |
| `bpm` | default tempo; the app may scale it (Practice mode) |
| `count_in_beats` | beats of click before beat 1 |
| `loop` + `repeats` | the step list repeats this many times; beat numbers continue |
| `steps[].beat` | 1-based, fractional allowed (1.5 = the "and") |
| `steps[].foot` | `L` or `R` |
| `steps[].class` | one of the step classes in README |

Beat `b` happens at `t0 + (b − 1) × 60000 / bpm` ms.
