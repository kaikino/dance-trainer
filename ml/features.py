#!/usr/bin/env python3
"""One row of step features per training window: the input for a tree model (XGBoost).

Usage: features.py runs/windows.npz -o runs/features.csv

The features are the 8 measurements the board's rule classifier makes of every
step (firmware rules.c rules_features_t, Python twin dt/baseline.py), so a model
trained on them can run on the board from the same numbers:

  dx_cm, dy_cm, dz_cm  movement from lift-off to landing: forward (toe), outward
                       (mirrored on the right foot, so the same on both), up
  zmax_cm              highest point of the swing
  pitch_min_deg        most toe-up shin angle during the swing
  pitch_range_deg      how far the shin rocked before landing
  roll_deg             sideways lean of the shin after landing (+ = outward)
  swing_ms             lift-off to landing

Other columns: label (class id), label_name, foot, session, dancer. Split by
dancer (or at least by session) when testing: rows from one session are not
independent.
"""
import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from dt import baseline
from dt.protocol import CLASS_NAMES

NAMES = {int(v): k for k, v in CLASS_NAMES.items()}

# rules_features_t name → dt/baseline.py features() key
FEATURES = {
    "dx_cm": "dx_cm", "dy_cm": "dy_cm", "dz_cm": "dz_cm", "zmax_cm": "zmax_cm",
    "pitch_min_deg": "pmin_deg", "pitch_range_deg": "prange_deg", "roll_deg": "roll_deg", "swing_ms": "swing_ms",
}


def table(npz: dict) -> pd.DataFrame:
    rows = []
    n = len(npz["x"])
    feet = npz["foot"] if "foot" in npz else np.array([""] * n)
    for i in range(n):
        f = baseline.features(npz["x"][i])
        row = {name: float(f[key]) for name, key in FEATURES.items()}
        y = int(npz["y"][i])
        row.update(label=y, label_name=NAMES.get(y, str(y)), foot=str(feet[i]),
                   session=str(npz["session"][i]), dancer=str(npz["dancer"][i]))
        rows.append(row)
    return pd.DataFrame(rows)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("windows", help="windows.npz from windows.py")
    ap.add_argument("-o", "--out", default="runs/features.csv")
    a = ap.parse_args()
    npz = dict(np.load(a.windows))
    df = table(npz)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out, index=False)
    print(f"{len(df)} steps × {len(FEATURES)} features → {out}")
    print(df.groupby(["label_name", "foot"]).size().unstack(fill_value=0).to_string())


if __name__ == "__main__":
    main()
