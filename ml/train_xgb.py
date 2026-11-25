#!/usr/bin/env python3
"""Train and test an XGBoost step classifier on per-step features (features.py).

Usage: train_xgb.py runs/tablet/features.csv --windows runs/tablet/windows.npz -o runs/tablet/xgb

Inputs: the 8 features the board measures per step (features.py FEATURES) plus
is_right (the node knows its foot). One multi-class model over all of the
firmware's step classes, so its class ids are the firmware's.

Testing: leave one session out (train on the rest, predict it), so steps from
one recording are never on both sides. With several dancers, prefer --group
dancer: that is the number that matters for a new user. Each fold reports:
  - xgb:            the model's top class over all classes
  - xgb + routine:  the top class among the steps in that session's routine
                    (what the board does; there it is a soft limit)
  - rules (+ routine): the board's rule classifier (dt/baseline.py, identical to
                    rules.c) on the same windows, for comparison
Then the final model is trained on everything and saved with its settings.
"""
import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd
import xgboost as xgb

from dt import baseline
from dt.protocol import CLASS_NAMES, N_CLASSES
from features import FEATURES

NAMES = {int(v): k for k, v in CLASS_NAMES.items()}
INPUTS = list(FEATURES) + ["is_right"]
PRESETS = Path(__file__).resolve().parent.parent / "presets"
DATA = Path(__file__).resolve().parent / "data"
NODE_BYTES = 12   # one tree node as a compact C array entry: feature, threshold, children / leaf value


def routine_mask(session_id: str) -> int:
    """Bit per class used by the session's routine (preset), 0 if unknown."""
    for meta in DATA.rglob(f"{session_id}/session.json"):
        pid = json.loads(meta.read_text())["preset_id"]
        for p in PRESETS.glob("*.json"):
            j = json.loads(p.read_text())
            if j["id"] == pid:
                mask = 0
                for s in j["steps"]:          # OR, not sum: a routine repeats its steps
                    mask |= 1 << int(CLASS_NAMES[s["class"]])
                return mask
    return 0


def masked_argmax(probs: np.ndarray, mask: int) -> int:
    if not mask:
        return int(probs.argmax())
    allowed = np.array([(mask >> c) & 1 for c in range(len(probs))], dtype=bool)
    return int(np.where(allowed, probs, -1).argmax())


def train(x: np.ndarray, y: np.ndarray, p: dict) -> xgb.Booster:
    d = xgb.DMatrix(x, label=y, feature_names=INPUTS)
    params = {"objective": "multi:softprob", "num_class": N_CLASSES, "max_depth": p["depth"], "eta": p["eta"],
              "min_child_weight": 1, "subsample": 1.0, "eval_metric": "mlogloss", "verbosity": 0, "seed": 0}
    return xgb.train(params, d, num_boost_round=p["rounds"])


def predict(b: xgb.Booster, x: np.ndarray) -> np.ndarray:
    return b.predict(xgb.DMatrix(x, feature_names=INPUTS))


def model_size(b: xgb.Booster) -> tuple[int, int, int]:
    t = b.trees_to_dataframe()
    return int(t["Tree"].nunique()), len(t), len(t) * NODE_BYTES


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("features")
    ap.add_argument("--windows", help="windows.npz the features came from (for the rule comparison)")
    ap.add_argument("--group", default="session", choices=["session", "dancer"])
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--rounds", type=int, default=50)
    ap.add_argument("--eta", type=float, default=0.3)
    ap.add_argument("-o", "--out", default="runs/xgb")
    a = ap.parse_args()
    p = {"depth": a.depth, "rounds": a.rounds, "eta": a.eta}

    df = pd.read_csv(a.features)
    df["is_right"] = (df["foot"] == "R").astype(float)
    x = df[INPUTS].to_numpy(dtype=np.float32)
    y = df["label"].to_numpy(dtype=int)
    masks = {s: routine_mask(s) for s in df["session"].unique()}
    rules = rules_m = None
    if a.windows:
        w = np.load(a.windows)["x"]
        assert len(w) == len(df), "windows.npz and features.csv do not line up"
        rules = np.array([int(baseline.classify(w[i])[0]) for i in range(len(df))])
        rules_m = np.array([int(baseline.classify(w[i], masks[df.session[i]])[0]) for i in range(len(df))])

    groups = df[a.group].to_numpy()
    pred = np.zeros(len(df), dtype=int)
    pred_m = np.zeros(len(df), dtype=int)
    print(f"Leave one {a.group} out ({len(set(groups))} folds), {len(df)} steps, "
          f"trees {a.depth} deep x {a.rounds} rounds x {N_CLASSES} classes:")
    for g in sorted(set(groups)):
        te = groups == g
        b = train(x[~te], y[~te], p)
        pr = predict(b, x[te])
        pred[te] = pr.argmax(1)
        mask = masks[df[a.group][te].iloc[0]] if a.group == "session" else 0
        pred_m[te] = [masked_argmax(r, mask) for r in pr]
        line = f"  {g:24s} {te.sum():3d} steps   xgb {np.mean(pred[te] == y[te]):4.0%}   xgb+routine {np.mean(pred_m[te] == y[te]):4.0%}"
        if rules is not None:
            line += f"   rules {np.mean(rules[te] == y[te]):4.0%}   rules+routine {np.mean(rules_m[te] == y[te]):4.0%}"
        print(line)

    print("\nAll held-out steps:")
    for name, pr in [("xgb", pred), ("xgb + routine", pred_m)] + (
            [("rules", rules), ("rules + routine", rules_m)] if rules is not None else []):
        by = "  ".join(f"{f} {np.mean(pr[df.foot == f] == y[df.foot == f]):4.0%}" for f in ("L", "R"))
        print(f"  {name:16s} {np.mean(pr == y):4.0%}   ({by})")

    print("\nxgb + routine, most common mistakes (true -> called):")
    for (t, c), n in Counter((NAMES[t], NAMES[c]) for t, c in zip(y, pred_m) if t != c).most_common(6):
        print(f"  {t:13s} -> {c:13s} {n}")

    final = train(x, y, p)
    gain = final.get_score(importance_type="gain")
    trees, nodes, nbytes = model_size(final)
    print("\nFeature importance (gain):", ", ".join(f"{k} {v:.1f}" for k, v in sorted(gain.items(), key=lambda kv: -kv[1])))
    print(f"Final model (all {len(df)} steps): {trees} trees, {nodes} nodes ≈ {nbytes / 1024:.0f} KB as C arrays")

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    final.save_model(out / "model.json")
    (out / "meta.json").write_text(json.dumps({
        "inputs": INPUTS, "num_class": N_CLASSES, "classes": {str(k): v for k, v in NAMES.items()}, **p,
        "steps": len(df), "groups": a.group,
        "cv_accuracy": float(np.mean(pred == y)), "cv_accuracy_routine": float(np.mean(pred_m == y)),
        "rules_accuracy": None if rules is None else float(np.mean(rules == y)),
        "rules_accuracy_routine": None if rules_m is None else float(np.mean(rules_m == y)),
        "trees": trees, "nodes": nodes,
    }, indent=2))
    print(f"→ {out}/model.json, {out}/meta.json")


if __name__ == "__main__":
    main()
