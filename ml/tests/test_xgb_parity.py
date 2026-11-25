"""xgb.c must call steps as the XGBoost model it was exported from (export_xgb.py).

Trains a small model on step features of simulated windows (the rule
classifier's calls as labels, so every branch of the trees is used), exports it
with export_xgb.py, compiles rules.c + xgb.c for the host with that header, and
compares, window by window: the class probabilities with xgboost's own, and the
board's call (top class, then the routine limit) with export_xgb.board_call.
If a trained model and its windows are present (runs/tablet), the same for it.
Run: python -m pytest tests/
"""
import ctypes
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest
import xgboost as xgb

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml"))
sys.path.insert(0, str(ROOT / "ml/tests"))

import export_xgb  # noqa: E402
import train_xgb  # noqa: E402
from dt import baseline  # noqa: E402
from dt.windows import CHANNELS, WIN_LEN  # noqa: E402
from features import FEATURES  # noqa: E402
from test_rules_parity import Features, StepWindow, random_windows, simulated_windows  # noqa: E402

SRC = ROOT / "firmware/dance_node/src"
N_CLASSES = 13


def build(header: Path) -> ctypes.CDLL:
    out = header.parent / "xgb.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-o", str(out), str(SRC / "rules.c"), str(SRC / "xgb.c"),
                    f"-I{SRC}", f'-DXGB_MODEL_HEADER="{header}"', "-lm"], check=True)
    lib = ctypes.CDLL(str(out))
    lib.xgb_classify.restype = ctypes.c_int
    lib.xgb_classify.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_uint16, ctypes.POINTER(ctypes.c_uint8),
                                 ctypes.c_void_p]
    lib.xgb_probs.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_void_p]
    return lib


def c_call(lib, w: np.ndarray, right: bool, vocab: int) -> tuple[int, int, np.ndarray]:
    sw, f, conf = StepWindow(), Features(), ctypes.c_uint8(0)
    ctypes.memmove(ctypes.addressof(sw.x), np.ascontiguousarray(w, dtype=np.int8).ctypes.data, WIN_LEN * len(CHANNELS))
    cls = lib.xgb_classify(ctypes.byref(sw), right, vocab, ctypes.byref(conf), ctypes.byref(f))
    probs = np.zeros(N_CLASSES, dtype=np.float32)
    lib.xgb_probs(ctypes.byref(f), right, probs.ctypes.data)
    return cls, conf.value, probs


def inputs(w: np.ndarray, right: bool) -> list[float]:
    f = baseline.features(w)
    return [float(f[k]) for k in FEATURES.values()] + [float(right)]


def compare(model_dir: Path, windows: list, right: list, vocabs: list) -> dict:
    header = model_dir / "xgb_model.h"
    text, _ = export_xgb.export(model_dir, None)
    header.write_text(text)
    lib = build(header)
    b = xgb.Booster()
    b.load_model(model_dir / "model.json")
    x = np.array([inputs(w, r) for w, r in zip(windows, right)], dtype=np.float32)
    py = b.predict(xgb.DMatrix(x, feature_names=train_xgb.INPUTS))
    worst, calls, confs = 0.0, 0, 0
    for w, r, v, p in zip(windows, right, vocabs, py):
        cls, conf, probs = c_call(lib, w, r, v)
        worst = max(worst, float(np.abs(probs - p).max()))
        pc, pconf = export_xgb.board_call(p, v)
        calls += cls != pc
        confs += abs(conf - pconf) > 1
    return {"n": len(windows), "worst_prob": worst, "calls": calls, "confs": confs}


def test_parity_small_model():
    rng = np.random.default_rng(1)
    ws = simulated_windows() + random_windows()[:200]
    right = [bool(i % 2) for i in range(len(ws))]
    x = np.array([inputs(w, r) for w, r in zip(ws, right)], dtype=np.float32)
    y = np.array([int(baseline.classify(w)[0]) for w in ws])
    d = Path(tempfile.mkdtemp())
    b = train_xgb.train(x, y, {"depth": 4, "rounds": 20, "eta": 0.3})
    b.save_model(d / "model.json")
    (d / "meta.json").write_text(json.dumps({"inputs": train_xgb.INPUTS, "num_class": N_CLASSES}))
    # Each window under no limit and under a random routine.
    vocabs = [0 if i % 3 == 0 else int(rng.integers(1, 1 << N_CLASSES)) for i in range(len(ws))]
    r = compare(d, ws, right, vocabs)
    assert r["worst_prob"] < 1e-4, r
    assert r["calls"] == 0 and r["confs"] == 0, r


def test_board_call_routine_limit():
    p = np.full(N_CLASSES, 0.01)
    fwd, fwd_out, side_out, back, in_place = (int(baseline.StepClass[n.upper()])
                                              for n in ("forward", "forward_out", "side_out", "back", "in_place"))
    p[fwd] = 0.9
    cls, conf = export_xgb.board_call(p, 0)
    assert cls == fwd and abs(conf - 230) <= 1
    assert export_xgb.board_call(p, 1 << fwd_out | 1 << back)[0] == fwd_out     # adjacent: replaced, not sure
    assert export_xgb.board_call(p, 1 << fwd_out)[1] == 159
    assert export_xgb.board_call(p, 1 << side_out | 1 << back)[0] == fwd          # 90° away: stays wrong
    p[:] = 0.01; p[in_place] = 0.9
    assert export_xgb.board_call(p, 1 << fwd)[0] == in_place                     # in place is never replaced


TRAINED = ROOT / "ml/runs/tablet"


@pytest.mark.skipif(not (TRAINED / "xgb/model.json").exists() or not (TRAINED / "windows.npz").exists(),
                    reason="no trained model in runs/tablet")
def test_parity_trained_model():
    d = Path(tempfile.mkdtemp())
    for f in ("model.json", "meta.json"):
        (d / f).write_text((TRAINED / "xgb" / f).read_text())
    npz = np.load(TRAINED / "windows.npz")
    ws = list(npz["x"])
    right = [str(f) == "R" for f in npz["foot"]]
    masks = {s: train_xgb.routine_mask(str(s)) for s in set(npz["session"])}
    vocabs = [masks[s] for s in npz["session"]]
    r = compare(d, ws, right, vocabs)
    assert r["calls"] == 0, r
    assert r["worst_prob"] < 1e-3, r
