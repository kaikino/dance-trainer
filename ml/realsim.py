#!/usr/bin/env python3
"""Adversarial simulation of the rule classifier on realistic steps (dt/footsim.py).

Every trial is a continuous IMU stream (previous step, stance, target step,
stance) pushed through the firmware pipeline (dt/node.py: Madgwick, foot frame,
strike detector, int8 window). Two pipelines are scored on the same streams:

  old: |a|-peak detector, 40+20 window, the original rule (dt/rules_v1.py)
  new: swing-end detector, 100+20 window, dt/baseline.py (= rules.c)

A target step counts as correct only if a window is cut for it AND classified
right; "missed" is its own column. Extra windows (beyond the previous step) are
counted separately.

Usage:
  realsim.py --n 300                 realistic ranges, per-class accuracy + confusion
  realsim.py --sweep all --n 60      each knob pushed past its realistic range
  realsim.py --sweep heading_deg,tempo --n 100
  realsim.py --json runs/realsim.json ...
"""
import argparse
import json
from dataclasses import replace
from multiprocessing import Pool

import numpy as np

from dt import baseline, node, rules_v1
from dt import footsim as F
from dt.protocol import StepClass

CLS = [int(c) for c in F.CLASSES]
NAMES = {int(c): c.name.lower() for c in StepClass}
MISSED = -1

# Knob → (realistic value or range, sweep values). Symmetric knobs sweep in 'edge'
# mode (every trial at ±value); range knobs sweep fixed values.
SWEEPS = {
    "acc_bias_g":      ("±0.05", [0.0, 0.05, 0.1, 0.2, 0.3]),
    "acc_scale":       ("±3%", [0.0, 0.03, 0.06, 0.1, 0.15]),
    "gyro_bias_dps":   ("±3", [0.0, 3.0, 6.0, 12.0, 24.0]),
    "gyro_scale":      ("±3%", [0.0, 0.03, 0.06, 0.1, 0.15]),
    "tilt_static_deg": ("±5", [0.0, 5.0, 10.0, 15.0, 20.0]),
    "tilt_dyn_deg":    ("±5", [0.0, 5.0, 10.0, 15.0, 20.0]),
    "cal_tilt_deg":    ("±5", [0.0, 5.0, 10.0, 15.0]),
    "heading_deg":     ("±20", [0.0, 10.0, 20.0, 30.0, 40.0]),
    "odr_err":         ("±2%", [0.0, 0.02, 0.05, 0.1]),
    "crosstalk_g":     ("0–0.6", [0.0, 0.6, 1.2, 2.0]),
    "gap_min_s":       ("≥0.06 s", [0.03, 0.06, 0.1, 0.2]),
    "land_speed":      ("×1", [0.0, 1.0, 2.0, 3.0]),
    "tempo":           ("70–140 bpm", [55, 70, 100, 140, 160, 180]),
    "height":          ("1.50–1.95 m", [1.35, 1.50, 1.70, 1.95, 2.05]),
    "step_size":       ("×0.55–1.15", [0.3, 0.4, 0.55, 0.8, 1.15]),
    "shock_hard":      ("3–8 g", [3.0, 8.0, 12.0, 16.0]),
    "soft_share":      ("15% (+lazy)", [0.0, 0.15, 0.5, 1.0]),
    "kick_angle":      ("30–80°", [20.0, 25.0, 30.0, 45.0, 80.0]),
    "kick_hold":       ("25%", [0.0, 1.0]),
    "toe_out":         ("in heading", [0.0, 10.0, 20.0, 30.0]),
}


def realism_for(knob: str | None, v) -> F.Realism:
    R = F.Realism()
    if knob is None:
        return R
    if knob == "tempo":
        return replace(R, tempo_bpm=(v, v))
    if knob == "height":
        return replace(R, height_m=(v, v))
    if knob == "step_size":
        return replace(R, lazy_p=1.0, lazy_scale=(v, v))
    if knob == "shock_hard":
        return replace(R, p_carpet=0.0, p_soft=0.0, shock_hard_g=(v, v))
    if knob == "soft_share":   # soft landings: slow floor stop (30-60 ms), no ringing, may not take weight
        return replace(R, p_soft=v)
    if knob == "kick_angle":
        return replace(R, kick_angle_deg=(v, v))
    if knob == "toe_out":
        return replace(R, toe_out_deg=(v, v))
    if knob == "kick_hold":
        return replace(R, kick_hold_p=v)
    if knob == "land_speed":
        return replace(R, land_speed=v)
    return replace(R, edge=frozenset([knob]), **{knob: v})


def run_trial(args) -> dict:
    cls, seed, foot, knob, v = args
    rng = np.random.default_rng(seed)
    tr = F.simulate(StepClass(cls), rng, realism_for(knob, v), foot=foot)
    fu, t = tr.fused, tr.fused["t"]
    lo = tr.t_lift if cls == StepClass.KICK else tr.t_contact - 0.15
    out = {"cls": cls, "foot": foot}
    for name, anchors, pre, post, rule in (
            ("old", node.detect(fu, node.OLD_DETECTOR), 40, 20, rules_v1.classify),
            ("new", node.detect_swing(fu, node.NEW_DETECTOR), node.NEW_DETECTOR.win_pre, node.NEW_DETECTOR.win_post,
             baseline.classify)):
        cand = [a for a in anchors if lo <= t[a] <= tr.t_contact + 0.25]
        extra = sum(1 for a in anchors if t[a] > tr.t_prev_contact + 0.25 and a not in cand) + max(len(cand) - 1, 0)
        if cand:
            a = min(cand, key=lambda a: abs(t[a] - tr.t_contact))
            w = node.cut(fu, a, foot == "R", pre, post)
            p, conf = rule(w)
            out[name] = (int(p), int(conf), extra, float(t[a] - tr.t_contact))
        else:
            out[name] = (MISSED, 0, extra, None)
    return out


def score(res: list[dict], name: str) -> dict:
    labels = CLS + [MISSED]
    cm = np.zeros((len(CLS), len(labels)), dtype=int)
    for r in res:
        cm[CLS.index(r["cls"]), labels.index(r[name][0])] += 1
    per = {NAMES[c]: cm[i, i] / max(cm[i].sum(), 1) for i, c in enumerate(CLS)}
    tot = sum(cm[i, i] for i in range(len(CLS))) / max(cm.sum(), 1)
    extras = sum(r[name][2] for r in res)
    confident_wrong = sum(1 for r in res if r[name][0] not in (MISSED, r["cls"]) and r[name][1] >= 160)
    return {"overall": tot, "per_class": per, "worst": min(per.values()), "cm": cm.tolist(),
            "missed": int(cm[:, -1].sum()), "extras": int(extras), "confident_wrong": confident_wrong, "n": len(res)}


def jobs(n: int, seed: int, knob=None, v=None):
    return [(c, seed + 7919 * k + 104729 * c, "LR"[k % 2], knob, v) for c in CLS for k in range(n)]


def print_cm(s: dict, title: str) -> None:
    hdr = [NAMES[c][:8] for c in CLS] + ["missed"]
    print(f"\n{title}: overall {s['overall']:.3f}, worst class {s['worst']:.3f}, "
          f"missed {s['missed']}, extra windows {s['extras']}, confident wrong {s['confident_wrong']} / {s['n']}")
    print(f"{'true \\ pred':>12} " + " ".join(f"{h:>8}" for h in hdr) + "    acc")
    for i, c in enumerate(CLS):
        row = s["cm"][i]
        print(f"{NAMES[c]:>12} " + " ".join(f"{x:8d}" for x in row) + f"  {s['per_class'][NAMES[c]]:.3f}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200, help="trials per class (per sweep point)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--sweep", default="", help="comma list of knobs, or 'all'")
    ap.add_argument("--json", default="")
    ap.add_argument("--procs", type=int, default=8)
    a = ap.parse_args()
    report = {}
    with Pool(a.procs) as pool:
        if not a.sweep:
            res = pool.map(run_trial, jobs(a.n, a.seed), chunksize=8)
            report["realistic"] = {k: score(res, k) for k in ("old", "new")}
            for k in ("old", "new"):
                print_cm(report["realistic"][k], f"{k.upper()} pipeline, realistic ranges")
        else:
            knobs = list(SWEEPS) if a.sweep == "all" else a.sweep.split(",")
            print(f"{'knob':>16} {'realistic':>14} {'value':>7}  {'old all':>7} {'old worst':>9}  {'new all':>7} {'new worst':>9} {'(class)':>10} {'miss':>4} {'extra':>5}")
            for knob in knobs:
                real, values = SWEEPS[knob]
                report[knob] = []
                for v in values:
                    res = pool.map(run_trial, jobs(a.n, a.seed, knob, v), chunksize=8)
                    so, sn = score(res, "old"), score(res, "new")
                    wc = min(sn["per_class"], key=sn["per_class"].get)
                    report[knob].append({"value": v, "old": so, "new": sn})
                    print(f"{knob:>16} {real:>14} {v:>7} {so['overall']:8.3f} {so['worst']:9.3f} {sn['overall']:8.3f} {sn['worst']:9.3f} {wc:>10} {sn['missed']:4d} {sn['extras']:5d}", flush=True)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1, default=float)


if __name__ == "__main__":
    main()
