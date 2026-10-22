#!/usr/bin/env python3
"""Cut int8 windows from labeled sessions.

Usage: windows.py data/* -o runs/windows.npz

Output arrays: x (N, 60, 9) int8, y (N,) int, dancer (N,) str, session (N,) str.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from dt import windows as W


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("sessions", nargs="+")
    ap.add_argument("-o", "--out", default="runs/windows.npz")
    a = ap.parse_args()

    xs, ys, dancers, sessions = [], [], [], []
    for s in a.sessions:
        d = Path(s)
        meta = json.loads((d / "session.json").read_text())
        ev = pd.read_csv(d / "events.csv")
        streams = {f: pd.read_csv(d / f"{f}.csv") for f in ("L", "R") if (d / f"{f}.csv").exists()}
        for _, row in ev.iterrows():
            if row["label_class"] < 0 or row["foot"] not in streams:
                continue
            w = W.cut(streams[row["foot"]], int(row["t_strike_node_us"]), row["foot"])
            if w is None:
                continue
            xs.append(w)
            ys.append(int(row["label_class"]))
            dancers.append(meta["dancer"])
            sessions.append(meta["session_id"])
        print(f"{d.name}: {len(ev)} events")

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, x=np.stack(xs), y=np.array(ys), dancer=np.array(dancers), session=np.array(sessions))
    print(f"{len(xs)} windows → {out}")


if __name__ == "__main__":
    main()
