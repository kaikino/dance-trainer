# Rule classifier: bench check on real feet

Run this the first time the boards are back, before trusting any score. It checks
the strike detector (`swingdet.c`) and the rule (`rules.c`) on real feet against
what the two simulators predict (`ml/realsim.py`: the author's `footsim.py` and the
auditor's `legsim.py`, which disagree; real data decides).

## Setup (1 min)

1. `make flash PORT=… ROLE=L CLASSIFIER=rules RULESDBG=1` (or any build, then type
   `rulesdbg on` in `make monitor`). Strap the node to the left ankle, USB-C to the toe.
2. `cal` **in the fixed stance**: feet parallel and under the hips (about one
   foot-width between them), weight on both, knees soft. The still pose sets roll
   0, and cross vs close is judged from roll, so a narrow or wide stance here
   shifts every cross/close call. Then do the three slides **straight forward
   from the body** (not along a turned-out toe). Wait for the double buzz.
   `status` must say `calibrated=1 forward=1`. Its second line is the gyro bias the
   node tracks while the foot is still; each axis should stay within ~10 dps.

Each strike prints one line, ~0.4 s after the landing:

```
rules t=… forward conf=201 | dx=27.3 dy=-2.1 dz=0.4 cm zmax=6.2 cm pitch=-18 range=31 roll=1.2 deg swing=420 ms zupt=0 settle=0 imp=100 s=56 e=106 | rules=forward 201
```

`dx` +toe, `dy` +outward (both feet), `zmax` swing height, `pitch` most toe-up
shank swing (negative), `roll` shank lean after landing (negative = inward),
`zupt` 0 = clean start found (1, 2 = fallbacks), `settle` 0 = the foot settled
inside the window (1 = it never did: the distance is less reliable). `conf` < 160
means the rule is unsure and the judge will not call the step wrong.

## Steps (3 min): five of each, normal size, then two small/lazy ones

| Do | Expect (simulators) | Class |
| --- | --- | --- |
| Lift and replace the foot | `dx`, `dy` within ±4 cm | in_place |
| Step forward | `dx` +12…+40, `dy` smaller than `dx` | forward |
| Step back | `dx` −12…−35 | back |
| Step out to the side | `dy` +12…+35 | side_out |
| From apart, close beside the other foot | `dy` −12…−35, `roll` > −5 (typ. −3…+3) | side_in |
| Cross in front, and behind, the other foot | `dy` −12…−50, `roll` ≤ −5 (typ. −8…−12) | cross |
| Kick forward and put the foot back | `pitch` ≤ −28 and back within 25 cm, or `zmax` ≥ 15 | kick |

## Real-data checks the simulators cannot settle

These are the assumptions the two simulators disagree on. Note the printed values.

1. **Roll with weight on and off.** In the calibration stance, shift all weight
   onto the left foot, hold 2 s, then onto the right; note `roll` on each node.
   The simulators assume up to ~5° inward roll on a loaded foot. Then do 5 closes
   and 5 crosses ending with the weight fully transferred, and 5 of each ending
   light (toe touch). If closes reach −5° or crosses stay above −5°, move
   `cross_roll_deg` in `ml/dt/baseline.py` (then `pytest tests/`, which lists the
   `rules.c` values to change).
2. **Slides.** Five forward and five side slides with no lift: one line each, in
   the right direction (the detector starts on |a_world| > 0.3 g and needs
   0.8 m/s of motion).
3. **Ball-of-foot landings.** Five forward and five back steps landing on the
   ball with the heel coming down after: `settle=0`, `e` 10–35 samples after
   `imp`, and `dx` within ~5 cm of the same step landed flat.
4. **140 bpm.** Eighth-note steps in place and side to side at 140 bpm. Count
   lines against steps: misses and doubled lines are the detector's weakest case
   in simulation (~10 %).
5. **Exactly one line per step** throughout; extra lines while standing mean the
   other foot's landing or the shank rolling passed the motion test.

## Pass / what to look at

- **Distances in cm, not just direction.** A forward step reading 10 cm when it
  was ~30: integration started mid-swing (`s` close to `imp`, `zupt` 1/2). If
  `dx`/`dy` are consistently rotated (forward shows large `dy`), redo `cal`;
  heading error beyond ~25° breaks the sectors.
- Repeat on the right ankle (`ROLE=R`): signs must be the same (outward = +`dy`).
- Record a Capture session of the same steps; the simulated ranges are a
  hypothesis until `baseline.py runs/windows.npz` on real windows agrees.
