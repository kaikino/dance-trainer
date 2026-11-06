# Preset format

`presets/<name>.json`. One file per choreography. The app loads it to draw the
step chart and to build the per-node schedule (see `docs/ble-protocol.md`).

```json
{
  "id": 3,
  "name": "Basic forward and back",
  "bpm": 96,
  "count_in_beats": 4,
  "loop": true,
  "repeats": 8,
  "length_beats": 8,
  "steps": [
    {"beat": 1.0, "foot": "L", "class": "forward"},
    {"beat": 2.0, "foot": "R", "class": "in_place"}
  ]
}
```

| field | meaning |
| --- | --- |
| `id` | u16, unique across presets; goes on the wire |
| `bpm` | default tempo; the app may scale it (Practice mode) |
| `count_in_beats` | beats of click before beat 1 |
| `loop` + `repeats` | the step list repeats this many times; beat numbers continue |
| `length_beats` | optional: beats in one loop, so a pattern can end on a rest; default: the last step's beat |
| `steps[].beat` | 1-based, fractional allowed (1.5 = the "and") |
| `steps[].foot` | `L` or `R` |
| `steps[].class` | one of the step classes below |
| `music` | optional: file name under `app/assets/music/`; without it the app plays a generated metronome (clicks on every beat, accent on 1) |

## Step classes

Each class is how the foot travels before it lands, relative to where it was.
Inward and outward are relative to the dancer's midline, so `side_out` is to
the left for the left foot and to the right for the right foot.

| class | the foot |
| --- | --- |
| `forward`, `back` | steps toward the toe / heel |
| `side_out` | steps outward, away from the other foot |
| `side_in` | steps inward to close up beside the other foot, without crossing |
| `cross` | steps inward past the other foot (in front or behind) |
| `in_place` | lifts and lands on the same spot, with or without weight (a tap) |
| `kick` | kicks forward without traveling |

## Routines must be danceable

`app/test/preset_test.dart` checks every preset: a foot may only travel while
the other foot can hold the weight (a traveling step puts the weight on the
stepping foot; `in_place` may or may not), and over one loop each foot's
forward and sideways travel adds up to zero, so the loop can repeat.

Beat `b` happens at `t0 + (b − 1) × 60000 / bpm` ms.
