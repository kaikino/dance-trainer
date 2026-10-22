# ML pipeline

```
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
```

| Step | Script | In → out |
| --- | --- | --- |
| 0 | `synth.py -o data` | synthetic sessions for pipeline dry runs (not for a shipping model) |
| 1 | app Capture mode | `data/<session>/` (docs/data-format.md) |
| 2 | `label.py data/*` | fills `label_class` by nearest scheduled beat; flags unusable |
| 3 | `windows.py data/* -o runs/windows.npz` | 60×9 int8 windows + labels + dancer ids |
| 4 | `baseline.py runs/windows.npz` | rule-classifier accuracy (the bar to clear) |
| 5 | `train.py runs/windows.npz` | leave-one-dancer-out CV, confusion matrices, `runs/model.keras` |
| 6 | `export.py runs/model.keras runs/windows.npz` | `firmware/dance_node/src/model_weights.h` (float weights for `cnn.c`) and selftest vectors |

`dt/` is the shared package: `protocol.py` (enums, must match `dt_protocol.h`),
`windows.py` (window geometry — must match `stepdet.h`), `baseline.py` (must
match `rules.c`).

## Invariants with the firmware

- Window: 40 samples before the strike, 20 after, 100 Hz. Channels in order:
  ax ay az gx gy gz (sensor), ax ay az (world, gravity removed).
- int8 quantization: `round(v / scale * 127)` per channel, scales in
  `dt/windows.py` and duplicated in `stepdet.c`.
- The network is run on the node by `cnn.c`, a hand-written float implementation
  of `train.py build()`. The model is trained on the int8 values as floats, so no
  rescaling happens on either side. Change the architecture in both places.
- `tests/test_rules_parity.py` compiles `rules.c` on the host and checks it
  against `dt/baseline.py`; `tests/test_cnn_parity.py` does the same for
  `cnn.c` against `runs/model.keras` on every window.
- `export.py --selftest` prints `idx,class,conf,us` for the 20 embedded test
  windows; the firmware's `selftest` command prints the same lines. They must
  match on class and be within ±2 on conf.
