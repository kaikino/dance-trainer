#!/usr/bin/env python3
"""Fill label_class in events.csv from the preset schedule (capture sessions).

Usage: label.py data/<session> [data/<session> ...]

For each strike, the nearest scheduled beat for that foot within ±MAX_MS becomes
the label. Strikes with no match and beats with no strike are dropped (label -1).
Manual labels (label_source == manual) are never overwritten.
"""
import json
import sys
from pathlib import Path

import pandas as pd

from dt.protocol import CLASS_NAMES

MAX_MS = 250
PRESETS = Path(__file__).resolve().parent.parent / "presets"


def load_preset(preset_id: int) -> dict:
    for p in PRESETS.glob("*.json"):
        j = json.loads(p.read_text())
        if j["id"] == preset_id:
            return j
    raise SystemExit(f"preset {preset_id} not found in {PRESETS}")


def expand(preset: dict) -> list[tuple[float, str, int]]:
    steps = preset["steps"]
    span = max(s["beat"] for s in steps)
    reps = preset.get("repeats", 1) if preset.get("loop") else 1
    return [(s["beat"] + r * span, s["foot"], CLASS_NAMES[s["class"]]) for r in range(reps) for s in steps]


def label_session(d: Path) -> None:
    meta = json.loads((d / "session.json").read_text())
    ev = pd.read_csv(d / "events.csv", dtype={"label_source": str, "foot": str}, keep_default_na=False)
    ev["label_class"] = pd.to_numeric(ev["label_class"], errors="coerce").fillna(-1).astype(int)
    preset = load_preset(meta["preset_id"])
    beat_ms = 60000 / meta["bpm"]
    t0_app_ms = meta["t0_app_ms"]

    for i, row in ev.iterrows():
        if row.get("label_source") == "manual":
            continue
        off = meta["nodes"][row["foot"]]["offset_us"]
        t_app_ms = (row["t_strike_node_us"] - off) / 1000.0
        best, best_d = None, MAX_MS + 1
        for beat, foot, cls in expand(preset):
            if foot != row["foot"]:
                continue
            d_ms = abs(t_app_ms - (t0_app_ms + (beat - 1) * beat_ms))
            if d_ms < best_d:
                best, best_d = cls, d_ms
        ev.at[i, "label_class"] = best if best is not None else -1
        ev.at[i, "label_source"] = "capture"

    ev.to_csv(d / "events.csv", index=False)
    n_ok = (ev["label_class"] >= 0).sum()
    print(f"{d.name}: {n_ok}/{len(ev)} labeled")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        label_session(Path(arg))
