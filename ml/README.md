# ML pipeline

```
python3.12 -m venv .venv && . .venv/bin/activate   # TensorFlow 2.17 needs Python 3.10-3.12, not 3.13+
pip install -r requirements.txt
```

| Step | Script | In → out |
| --- | --- | --- |
| 0 | `synth.py -o data` | synthetic sessions for pipeline dry runs (not for a shipping model) |
| 1 | app Capture mode | `data/<session>/` (docs/data-format.md) |
| 2 | `label.py data/*` | fills `label_class` by nearest scheduled beat; flags unusable |
| 3 | `windows.py data/* -o runs/windows.npz` | 140×9 int8 windows + labels + dancer ids |
| 4 | `baseline.py runs/windows.npz` | rule-classifier accuracy (the bar to clear) |
| – | `realsim.py`, `realsim.py --seed 2` (held out), `realsim.py --sweep all` | rule + detector on two independent physical simulators (`dt/footsim.py`, `dt/legsim.py`) and stress conditions, 218e818 vs now |
| 5 | `train.py runs/windows.npz` | leave-one-dancer-out CV, confusion matrices, `runs/model.keras` |
| 6 | `export.py runs/model.keras runs/windows.npz` | `firmware/dance_node/src/model_weights.h` (float weights for `cnn.c`) and selftest vectors |

`dt/` is the shared package: `protocol.py` (enums, must match `dt_protocol.h`),
`windows.py` (window geometry — must match `stepdet.h`), `baseline.py` (must
match `rules.c`), `node.py` (Python port of the node pipeline: Madgwick, foot
frame, strike detector — `detect_swing` must match `swingdet.c` — and window
cut), `footsim.py` and `legsim.py` (two independent physical foot/shank/IMU simulators used by `realsim.py`; `legsim.py` is the auditor's two-leg model), `rules_v2.py` (the 218e818 detector and rule, frozen for comparison),
`rules_v1.py` (the pre-rework rule, for comparison only).

## Invariants with the firmware

- Window: 100 samples before the strike, 40 after, 104 Hz (the IMU's ODR). Channels in order:
  ax ay az gx gy gz (calibrated sensor frame: +z up, +x toe), ax ay az (foot
  frame, gravity removed). The right foot is mirrored on y in both groups so
  +y = outward on both feet (`MIRRORED_FOOT` in `dt/windows.py`, `stepdet.c`).
  Because calibration fixes both down and forward, none of the nine channels
  depends on how the board sits on the strap.
- int8 quantization: `round(v / scale * 127)` per channel, scales in
  `dt/windows.py` and duplicated in `stepdet.c` (accel 8 g, gyro 2000 dps).
- The network is run on the node by `cnn.c`, a hand-written float implementation
  of `train.py build()`. The model is trained on the int8 values as floats, so no
  rescaling happens on either side. Change the architecture in both places.
- `tests/test_rules_parity.py` compiles `rules.c` on the host and checks it
  against `dt/baseline.py` (thresholds, random and simulated windows);
  `tests/test_stepdet_parity.py` checks `swingdet.c` against
  `dt/node.py detect_swing`; `tests/test_cnn_parity.py` does the same for
  `cnn.c` against `runs/model.keras` on every window.
- `export.py --selftest` prints `idx,class,conf,us` for the 20 embedded test
  windows; the firmware's `selftest` command prints the same lines. They must
  match on class and be within ±2 on conf.
