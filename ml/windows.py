#!/usr/bin/env python3
"""Cut int8 windows from labeled sessions.

Usage: windows.py data/* -o runs/windows.npz

Output arrays: x (N, WIN_LEN, 9) int8, y (N,) int, dancer (N,) str, session (N,) str.
Skips sessions whose mode is not capture, rows with label_class < 0, and rows
that are node-synthesised missed beats (verdict == missed).
Strikes are located by the t_app_ms column when the export has it, else by the
u32 node time, unwrapped so a session across the ~71.6 min wrap works.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from dt import windows as W
from dt.session import is_capture, usable_events


def session_windows(d: Path) -> tuple[list[np.ndarray], list[int], dict]:
    """Windows and labels for one session directory ([] if it is skipped)."""
    meta = json.loads((d / "session.json").read_text())
    if not is_capture(meta):
        print(f"{d.name}: mode {meta.get('mode')!r}, skipped")
        return [], [], meta
    ev = pd.read_csv(d / "events.csv", dtype={"foot": str, "label_source": str}, keep_default_na=False)
    ev["label_class"] = pd.to_numeric(ev["label_class"], errors="coerce").fillna(-1).astype(int)
    streams = {f: W.load_stream(d / f"{f}.csv") for f in ("L", "R") if (d / f"{f}.csv").exists()}
    keep = usable_events(ev) & (ev["label_class"] >= 0)
    by_app = "t_app_ms" in ev.columns
    if by_app:
        ev["t_app_ms"] = pd.to_numeric(ev["t_app_ms"], errors="coerce")

    xs, ys = [], []
    for foot, rows in ev.groupby("foot", sort=False):
        df = streams.get(foot)
        if df is None or df.empty:
            continue
        # Newer exports: locate the strike by app time (survives the clock wrap
        # and a node reboot). Otherwise by node time: strikes are u32 like the raw
        # stream, so put each on the stream's unwrapped scale, within ±2^31 µs of
        # the previous strike of this foot.
        t_app = rows["t_app_ms"] if by_app else pd.Series(float("nan"), index=rows.index)
        t_us = W.unwrap_near(rows["t_strike_node_us"].to_numpy(), int(df["t_node_us"].iloc[0]))
        for (i, row), t in zip(rows.iterrows(), t_us):
            if not keep[i]:
                continue
            if by_app and W.has_app_time(df) and pd.notna(t_app[i]):
                w = W.cut_app(df, float(t_app[i]), foot)
            else:
                w = W.cut(df, int(t), foot)
            if w is None:
                continue
            xs.append(w)
            ys.append(int(row["label_class"]))
    print(f"{d.name}: {len(ev)} events, {len(xs)} windows")
    return xs, ys, meta


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("sessions", nargs="+")
    ap.add_argument("-o", "--out", default="runs/windows.npz")
    a = ap.parse_args()

    xs, ys, dancers, sessions = [], [], [], []
    for s in a.sessions:
        wx, wy, meta = session_windows(Path(s))
        xs += wx
        ys += wy
        dancers += [meta.get("dancer", "")] * len(wx)
        sessions += [meta.get("session_id", Path(s).name)] * len(wx)

    if not xs:
        raise SystemExit("no windows: nothing labeled and usable in these sessions (run label.py first?)")
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, x=np.stack(xs), y=np.array(ys), dancer=np.array(dancers), session=np.array(sessions))
    print(f"{len(xs)} windows → {out}")


if __name__ == "__main__":
    main()
