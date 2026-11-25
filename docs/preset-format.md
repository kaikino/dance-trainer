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
| `beats_per_bar` | optional time signature: 3 for 3/4 (a waltz box step), default 4; sets bar lines, the music's bars (a waltz in 3/4), bar numbers and practice rewinds |
| `count_in_beats` | beats of click before beat 1 |
| `loop` + `repeats` | the step list repeats this many times; beat numbers continue |
| `length_beats` | optional: beats in one loop, so a pattern can end on a rest; default: the last step's beat |
| `steps[].beat` | 1-based, fractional allowed (1.5 = the "and") |
| `steps[].foot` | `L` or `R` |
| `steps[].class` | one of the step classes below |
| `steps[].weight` | optional, default true: `false` for a touch, where the foot lands but the weight stays on the other foot (the close on 4 in a grapevine) |
| `music` | optional: file name under `app/assets/music/`; without it the app makes a backing track at the routine's tempo (`app/lib/audio/song_synth.dart`: sticks for the count-in, then a groove with a sharp hit on every beat; its style follows the id, a waltz in 3/4). The song select previews the same music |

## Step classes

Each class is how the foot travels before it lands, relative to where it was.
Inward and outward are relative to the dancer's midline, so `side_out` is to
the left for the left foot and to the right for the right foot.

| class | the foot |
| --- | --- |
| `forward`, `back` | steps toward the toe / heel |
| `side_out` | steps outward, away from the other foot |
| `side_in` | steps inward to close up beside the other foot, without crossing |
| `cross` | steps inward past the other foot, in front of it |
| `cross_behind` | steps inward past the other foot, behind it |
| `forward_out`, `forward_in` | steps diagonally forward and out / in: `forward_out` is forward-left for the left foot and forward-right for the right; `forward_in` the opposite |
| `back_out`, `back_in` | the same, diagonally backward: `back_out` is back-left for the left foot, back-right for the right |
| `in_place` | lifts and lands on the same spot, with or without weight (a tap) |
| `kick` | kicks forward without traveling |

In dance mode each node is told which classes its part of the routine uses. A
travelling step that lands between two direction sectors (they are 45° wide, so
a sloppy diagonal is easily half forward) is then called as the routine's step
when that step is in the neighbouring sector; such a call is never "sure", so at the default threshold it
can't be scored as a wrong step. A step that clearly went another way is still
called what it was. One classifier serves every dance this way, instead of a
model per dance.

## Routines must be danceable

`app/test/preset_test.dart` checks every preset: a foot may only travel while
the other foot can hold the weight (a traveling step puts the weight on the
stepping foot; `in_place` may or may not), and over one loop each foot's
forward travel adds up to zero (a diagonal counts one unit forward or back), and
a foot that moves sideways one way also moves the other way, so the loop can
repeat. Sideways only the direction is checked, because step sizes differ: in a
grapevine a cross plus a close undoes two side steps.

Beat `b` happens at `t0 + (b − 1) × 60000 / bpm` ms.
