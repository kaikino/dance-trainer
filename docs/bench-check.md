# Rule classifier: 5-minute bench check

Run this the first time the boards are back, before trusting any score. It checks
the strike detector and the rule (`rules.c`) on real feet against what the
simulator (`ml/realsim.py`) predicts.

## Setup (1 min)

1. `make flash PORT=… ROLE=L CLASSIFIER=rules RULESDBG=1` (or any build, then type
   `rulesdbg on` in `make monitor`). Strap the node to the left ankle, USB-C to the toe.
2. `cal`: stand still, then do the three slides **straight forward from the body**
   (not along a turned-out toe). Wait for the double buzz. `status` must say
   `calibrated=1 forward=1`.

Each strike prints one line:

```
rules t=… forward conf=201 | dx=27.3 dy=-2.1 dz=0.4 cm zmax=6.2 cm pitch=-18 range=31 roll=1.2 deg swing=420 ms zupt=0 imp=100 s=56 e=102 | rules=forward 201
```

`dx` +toe, `dy` +outward (both feet), `zmax` swing height, `pitch` most toe-up
shank swing (negative), `roll` shank lean after landing (negative = inward),
`zupt` 0 = clean start found (1, 2 = fallbacks; a few are fine, many are not).

## Steps (3 min): five of each, normal size, then two small/lazy ones

| Do | Expect (simulator 5–95 %) | Class |
| --- | --- | --- |
| Lift and replace the foot | `dx`, `dy` within ±4 cm | in_place |
| Step forward | `dx` +12…+37, `dy` smaller than `dx` | forward |
| Step back | `dx` −13…−34 | back |
| Step out to the side | `dy` +13…+35 | side_out |
| From apart, close beside the other foot | `dy` −12…−39, `roll` > −4 | side_in |
| Cross in front, and behind, the other foot | `dy` −20…−60, `roll` ≤ −4 (typ. −13) | cross |
| Kick forward and put the foot back | `pitch` ≤ −28 or `range` ≥ 55 (low kick: `pitch` ≤ −18 and back within 15 cm) | kick |

Then: two steps on carpet or in socks, and a few at ~140 bpm.

## Pass / what to look at (1 min)

- **Exactly one line per step.** Missing lines on soft steps: the impact never
  reached 1.25 g and the foot took > 14 samples to go quiet (`swingdet.c`). Extra
  lines while standing: the other foot's landing passed the 12-sample / 80 dps gate.
- **Distances in cm, not just direction.** A forward step reading 10 cm when it was
  ~30: integration started mid-swing (`s` close to `imp`, `zupt` 1/2). If `dx`/`dy`
  are consistently rotated (forward shows large `dy`), redo `cal`; heading error
  beyond ~25° breaks the sectors.
- **Cross vs close** rests on `roll`. Note the values for both; if real crosses sit
  above −4° or closes below it, move `cross_roll_deg` in `ml/dt/baseline.py`, run
  `pytest tests/` (a failing `test_thresholds_match` lists the `#define` values
  `rules.c` needs), then re-run `realsim.py`.
- Repeat on the right ankle (`ROLE=R`): signs must be the same (outward = +`dy`).
- Record a Capture session of the same steps; `realsim.py` ranges are a hypothesis
  until `baseline.py runs/windows.npz` on real windows agrees.
