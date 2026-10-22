#!/usr/bin/env python3
"""Synthetic capture sessions in the recorded-data format, for pipeline dry runs.

Usage: synth.py -o data --dancers 6 --sessions-per-dancer 4 [--seed 1]

Each session: a preset danced at its bpm with per-dancer timing jitter and
amplitude. Steps are crude kinematic sketches, not real dance data; they exist
so label.py → windows.py → train.py → export.py can be exercised end to end
before Capture mode produces real recordings. Don't train a shipping model on it.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from dt.protocol import CLASS_NAMES, StepClass

ROOT = Path(__file__).resolve().parent.parent
PRESETS = sorted((ROOT / "presets").glob("*.json"))
RATE = 100

# Foot-frame displacement direction per class (x = toe, y = outward), in g·s² units
# that produce a visible accel pulse; kick is a bigger forward pulse without the plant.
PROFILE = {
    StepClass.IN_PLACE: (0.0, 0.0, 1.6),
    StepClass.FORWARD: (0.9, 0.0, 1.8),
    StepClass.BACK: (-0.9, 0.0, 1.8),
    StepClass.SIDE_OUT: (0.0, 0.9, 1.8),
    StepClass.CROSS: (0.1, -0.9, 1.8),
    StepClass.KICK: (1.8, 0.0, 2.4),
}


def step_pulse(n_pre: int, n_post: int, dx: float, dy: float, peak: float, rng) -> np.ndarray:
    """Accel (sensor≈foot frame, g, gravity included) around one strike. Returns (n, 6): ax ay az gx gy gz."""
    n = n_pre + n_post
    t = np.arange(n) / RATE
    out = np.zeros((n, 6), dtype=np.float32)
    # Swing: accelerate then decelerate toward the strike (double-sided pulse in x/y).
    swing = np.sin(2 * np.pi * (t[:n_pre] - t[0]) / (2 * n_pre / RATE))  # one full period over the swing
    out[:n_pre, 0] = dx * swing * 1.2
    out[:n_pre, 1] = dy * swing * 1.2
    # Strike: vertical spike at index n_pre, then settle.
    out[n_pre, 2] += peak
    out[n_pre + 1, 2] += peak * 0.4
    # Gyro: pitch during swing proportional to forward motion, roll for sideways.
    out[:n_pre, 4] = dx * 200 * np.cos(np.pi * t[:n_pre] / (n_pre / RATE))
    out[:n_pre, 3] = dy * 200 * np.cos(np.pi * t[:n_pre] / (n_pre / RATE))
    out[:, 2] += 1.0  # gravity
    out += rng.normal(0, 0.03, out.shape).astype(np.float32)
    out[:, 3:] += rng.normal(0, 3, (n, 3)).astype(np.float32)
    return out


def synth_session(dancer: str, preset: dict, idx: int, rng, out_dir: Path) -> None:
    bpm = preset["bpm"] * rng.uniform(0.9, 1.1)
    beat_ms = 60000 / bpm
    steps = preset["steps"]
    span = max(s["beat"] for s in steps)
    reps = preset.get("repeats", 1) if preset.get("loop") else 1
    sched = [(s["beat"] + r * span, s["foot"], CLASS_NAMES[s["class"]]) for r in range(reps) for s in steps]
    total_ms = (max(b for b, _, _ in sched) + 2) * beat_ms + 2000
    n = int(total_ms / 1000 * RATE)
    t0_app_ms = 1_700_000_000_000 + idx * 600_000
    amp = rng.uniform(0.8, 1.2)
    jitter_ms = rng.uniform(20, 70)

    sid = f"synth-{dancer}-{idx:02d}"
    d = out_dir / sid
    d.mkdir(parents=True, exist_ok=True)
    nodes, events = {}, []
    for foot in ("L", "R"):
        offset_us = int(rng.integers(1_000_000, 50_000_000))
        t_node_us = (np.arange(n) * 10_000 + 1_000_000 + offset_us).astype(np.int64)
        sig = np.zeros((n, 6), dtype=np.float32)
        sig[:, 2] = 1.0
        sig += rng.normal(0, 0.02, sig.shape).astype(np.float32)
        for beat, f, cls in sched:
            if f != foot:
                continue
            t_ms = 1000 + (beat - 1) * beat_ms + rng.normal(0, jitter_ms)
            i = int(t_ms / 1000 * RATE)
            n_pre, n_post = 45, 25
            if i - n_pre < 0 or i + n_post > n:
                continue
            dx, dy, pk = PROFILE[StepClass(cls)]
            if foot == "L":
                dy = -dy  # sensor y is mirrored for the left foot
            sig[i - n_pre : i + n_post] += step_pulse(n_pre, n_post, dx * amp, dy * amp, pk * amp, rng) - np.array([0, 0, 1, 0, 0, 0], dtype=np.float32)
            events.append({
                "t_strike_node_us": int(t_node_us[i]), "foot": foot,
                "step_class": 0, "confidence": 0, "expected_class": cls, "timing_err_ms": 0, "verdict": 0,
                "label_class": -1, "label_source": "",
            })
        df = pd.DataFrame({
            "t_node_us": t_node_us,
            "ax": (sig[:, 0] * 1000).round().astype(int), "ay": (sig[:, 1] * 1000).round().astype(int), "az": (sig[:, 2] * 1000).round().astype(int),
            "gx": (sig[:, 3] * 10).round().astype(int), "gy": (sig[:, 4] * 10).round().astype(int), "gz": (sig[:, 5] * 10).round().astype(int),
            "qw": 1.0, "qx": 0.0, "qy": 0.0, "qz": 0.0,  # identity: synthetic sensor frame == level
        })
        df.to_csv(d / f"{foot}.csv", index=False)
        # t_app_ms = (t_node_us - offset_us) / 1000; sample 0 is at t0_app_ms - 1000 ms (beat 1 at +1000 ms).
        nodes[foot] = {"offset_us": int(t_node_us[0] - (t0_app_ms - 1000) * 1000), "fw_version": 1}

    pd.DataFrame(events).sort_values("t_strike_node_us").to_csv(d / "events.csv", index=False)
    (d / "session.json").write_text(json.dumps({
        "session_id": sid, "dancer": dancer, "preset_id": preset["id"], "preset_name": preset["name"],
        "bpm": bpm, "mode": "capture", "t0_app_ms": t0_app_ms, "nodes": nodes,
        "app_version": "synth", "protocol_version": 1,
    }, indent=2))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="data")
    ap.add_argument("--dancers", type=int, default=6)
    ap.add_argument("--sessions-per-dancer", type=int, default=4)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    presets = [json.loads(p.read_text()) for p in PRESETS]
    k = 0
    for di in range(a.dancers):
        for si in range(a.sessions_per_dancer):
            synth_session(f"d{di}", presets[si % len(presets)], k, rng, Path(a.out))
            k += 1
    print(f"{k} sessions → {a.out}/")


if __name__ == "__main__":
    main()
