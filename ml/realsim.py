#!/usr/bin/env python3
"""Rule fallback (strike detector + rules.c) on simulated feet, OLD vs NEW.

Two independent physical simulators disagree about the things that matter most
(how much the shank rolls and keeps rotating after contact, heel drop after a
ball landing, strap ringing, calibration stance), so the rule is scored on both
and on their union:

  author    dt/footsim.py: one target step per trial (stand, previous step of the
            same foot, short stance, target step, stance), Realism() ranges.
  auditor   dt/legsim.py: two-leg routines (whole body, IK, weight transfer,
            strap wobble, calibration stance width), "realistic" settings.
  stress    dt/legsim.py routines, each with one condition pushed to the edge of
            what either model calls plausible: slides, 1-3 cm lifts, ball or heel
            landings, 140 bpm eighths, low kicks, narrow/wide calibration stance,
            a sensor high on the shank, socks, carpet, turned-out feet, big crosses.
  mixed     the three pooled.

Every stream goes through the firmware pipeline (dt/node.py: Madgwick, foot frame,
strike detector, int8 window, rule). A step is correct only if a window is cut
for it (anchor within -0.15..+0.25 s of the landing; kicks from lift-off) AND it
is classified right. "missed" = no window; "extra" = a window matching no step;
"cwrong" = wrong class with confidence >= 160 (the judge's default threshold;
a lower-confidence wrong call is forgiven by judge.c, not scored as wrong).

  old   218e818 (dt/rules_v2.py, frozen)
  new   dt/node.py detect_swing + dt/baseline.py (= swingdet.c + rules.c)

Usage:
  realsim.py                         dev seed: author, auditor, stress, mixed
  realsim.py --seed 2                held-out seed (do not tune on it)
  realsim.py --sets auditor --n 60   one set, bigger
  realsim.py --sweep all --n 60      author simulator, each knob past its range
  realsim.py --sets dance_box,dance_grapevine --pipes new,vocab
                                     one dance's routines, rule without / with the routine's classes
Streams are cached in runs/simcache/ (delete to regenerate).
"""
import argparse
import json
import os
import pickle
from dataclasses import replace
from multiprocessing import Pool
from pathlib import Path

import numpy as np

from dt import baseline, node, rules_v2
from dt import footsim as F
from dt import legsim as L
from dt.protocol import StepClass

CLS = [int(c) for c in F.CLASSES]
NAMES = {int(c): c.name.lower() for c in StepClass}
IDS = {v: k for k, v in NAMES.items()}
MISSED = -1
CONF_THR = 160
CACHE = Path(__file__).resolve().parent / "runs" / "simcache"

# ---- pipelines -------------------------------------------------------------------------


def pipe_old(fused, right):
    out = []
    for a in rules_v2.detect_swing(fused, rules_v2.DETECTOR):
        w = node.cut(fused, a, right, 100, 20)
        f = rules_v2.features(w)
        c, conf = rules_v2.decide(f)
        out.append((a, int(c), int(conf), f))
    return out


def pipe_new(fused, right, vocab=0):
    det = node.NEW_DETECTOR
    out = []
    for a in node.detect_swing(fused, det):
        w = node.cut(fused, a, right, det.win_pre, det.win_post)
        f = baseline.features(w)
        c, conf = baseline.decide(f, vocab=vocab)
        out.append((a, int(c), int(conf), f))
    return out


PIPES = {"old": pipe_old, "new": pipe_new}
# "vocab": the new pipeline told which classes the routine uses (the node knows
# its schedule), as judge.c does in dance mode. Streams carry s["vocab"].
VOCAB_PIPE = "vocab"


def _pipe(name):
    """A PIPES key, or "module:function" for an experimental pipeline."""
    if name in PIPES:
        return PIPES[name]
    import importlib
    mod, fn = name.split(":")
    return getattr(importlib.import_module(mod), fn)

# ---- stream generation -----------------------------------------------------------------
# A stream: dict(fused, right, events=[dict(t_c, lo, cls|None, info)], extra_from).
# Events with cls None (the author trial's previous step) may take a window but are
# not scored.

# The auditor's "realistic" setting (his run.py/sweep.py "real"): weight shift may
# lead the swing by up to 0.15 s.
AUD_REAL = dict(shift_lead=(0.0, 0.15))
STRESS = {
    "slides": (dict(p_slide=1.0), {}),
    "lowlift": (dict(lift=(0.01, 0.03)), {}),
    "ball": (dict(p_land={"ball": 1.0}), {}),
    "heel": (dict(p_land={"heel": 1.0}), {}),
    "t140e": (dict(step_scale=0.6, lift=(0.02, 0.05)),
              dict(bpm=140, eighth=True, cls_p=dict(in_place=1, forward=1, back=1, side_out=1, cross=1, side_in=3,
                                                   forward_out=0.8, forward_in=1.5, back_out=0.8, back_in=1.5,
                                                   cross_behind=1))),
    "t140q": ({}, dict(bpm=140)),
    "lowkick": (dict(kick_phi=(20, 35)), {}),
    "calnarrow": (dict(cal_w=0.05), {}),
    "calwide": (dict(cal_w=0.35), {}),
    "calhip": (dict(cal_w="hip"), {}),          # the fixed calibration stance the docs ask for
    "highstrap": (dict(d_s=0.14, r_off=0.06), {}),
    "socks": (dict(footwear="socks", wob_f=35, wob_z=0.6), {}),
    "carpet": (dict(footwear="carpet", wob_f=15, wob_z=0.3), {}),
    "turnout30": (dict(turnout=30), {}),
    "bigcross": (dict(pelvis_yaw=25, extra_rot=30), {}),
    "rawpelvis": (dict(hz_smooth=0.0), {}),      # the auditor's original pelvis (see legsim.py)
}


def _fused_legsim(rng, dz, t, A, C, pyaw, lrot, bumps, o):
    acc, gyr, RC = L.imu(rng, dz, t, A, C, pyaw, lrot, bumps, o)
    n = len(acc)
    t_us = (np.arange(n) * (1e6 / 104)).astype(np.int64) + 1000
    fu = node.fuse(t_us, acc, gyr, o < 0, L.quat_from_R(RC[0]))
    fu["t"] = t_us * 1e-6
    return fu


def gen_routine(args):
    seed, over, rkw, tag = args
    rng = np.random.default_rng(seed)
    dz = L.Dancer(rng, over)
    bpm = rkw.get("bpm") or float(rng.uniform(70, 130))
    steps, t_end = L.plan_routine(rng, dz, rkw.get("n", 14), bpm, rkw.get("eighth", False),
                                  rkw.get("classes"), rkw.get("cls_p"))
    t, A, C, pyaw, lrot, bumps = L.build(rng, dz, steps, t_end)
    out = []
    for o in (+1, -1):
        fu = _fused_legsim(rng, dz, t, A, C, pyaw, lrot, bumps, o)
        ev = [dict(t_c=s["t_c"], lo=s["t_lift"] if s["cls"] == "kick" else s["t_c"] - 0.15, cls=IDS[s["cls"]],
                   info=dict(tag=tag, land=s["land"], slide=bool(s["slide"]), lift=s["lift"], fw=dz.footwear,
                             tdx=float((s["P1"] - s["P0"])[0] * 100), tdy=float((s["P1"] - s["P0"])[1] * 100 * o),
                             cal_w=dz.cal_w, d_s=dz.d_s, bpm=bpm, t_lift=float(s["t_lift"]), t_c=float(s["t_c"]),
                             T_sw=float(s["T_sw"])))
              for s in steps if s["foot"] == o]
        out.append(dict(fused=fu, right=o < 0, events=ev, extra_from=1.0))
    return out


def gen_trial(args):
    cls, seed, foot, R = args
    rng = np.random.default_rng(seed)
    tr = F.simulate(StepClass(cls), rng, R, foot=foot)
    d = tr.truth["disp_cm"]
    ev = [dict(t_c=tr.t_prev_contact, lo=tr.t_prev_contact - 0.15, cls=None, info={}),
          dict(t_c=tr.t_contact, lo=tr.t_lift if cls == StepClass.KICK else tr.t_contact - 0.15, cls=cls,
               info=dict(tag="author", tdx=float(d[0]), tdy=float(d[1]), bpm=tr.truth["bpm"],
                         t_lift=float(tr.t_lift), t_c=float(tr.t_contact)))]
    return [dict(fused=tr.fused, right=foot == "R", events=ev, extra_from=1.0)]


def jobs_author(n, seed, R=None):
    R = R or F.Realism()
    return [(c, seed * 100003 + 7919 * k + 104729 * c, "LR"[k % 2], R) for c in CLS for k in range(n)]


def jobs_auditor(n, seed):
    return [(seed * 100003 + 1000 * i, AUD_REAL, {}, "auditor") for i in range(n)]


# Routines built only from one dance's steps (the auditor's simulator). The
# vocabulary is what the node is told; side_in is in the grapevine set because the
# simulator needs it to bring the feet back together.
DANCES = {
    "box": ["forward_out", "forward_in", "back_out", "back_in", "in_place"],
    "grapevine": ["side_out", "cross_behind", "side_in", "in_place"],
    "side": ["side_out", "side_in", "in_place"],
    "basic": ["forward", "back", "in_place"],
}


def vocab_mask(classes) -> int:
    return sum(1 << int(IDS[c]) for c in classes)


def jobs_dance(dance, n, seed):
    return [(seed * 100003 + 1000 * i + 29, AUD_REAL, {"classes": DANCES[dance]}, f"dance_{dance}")
            for i in range(n)]


def jobs_stress(n, seed):
    keys = list(STRESS)
    out = []
    for i in range(n):
        k = keys[i % len(keys)]
        over, rkw = STRESS[k]
        out.append((seed * 100003 + 1000 * i + 17, {**AUD_REAL, **over}, rkw, k))
    return out


def streams(pool, name, n, seed):
    CACHE.mkdir(parents=True, exist_ok=True)
    p = CACHE / f"{name}_n{n}_s{seed}.pkl"
    if p.exists():
        return pickle.loads(p.read_bytes())
    if name == "author":
        res = pool.map(gen_trial, jobs_author(n, seed), chunksize=4)
    elif name == "auditor":
        res = pool.map(gen_routine, jobs_auditor(n, seed), chunksize=1)
    elif name == "stress":
        res = pool.map(gen_routine, jobs_stress(n, seed), chunksize=1)
    elif name.startswith("dance_"):
        res = pool.map(gen_routine, jobs_dance(name[6:], n, seed), chunksize=1)
    else:
        raise ValueError(name)
    st = [s for r in res for s in r]
    if name.startswith("dance_"):
        for s_ in st:
            s_["vocab"] = vocab_mask(DANCES[name[6:]])
    p.write_bytes(pickle.dumps(st))
    return st


# ---- scoring -----------------------------------------------------------------------------


def eval_stream(args):
    """Match the pipeline's windows to the stream's steps. Returns per-step rows and extras."""
    s, pname = args
    fu, right = s["fused"], s["right"]
    t = fu["t"]
    res = pipe_new(fu, right, s.get("vocab", 0)) if pname == VOCAB_PIPE else _pipe(pname)(fu, right)
    used = set()
    rows = []
    for ev in sorted(s["events"], key=lambda e: e["t_c"]):
        cand = [i for i, r in enumerate(res) if i not in used and ev["lo"] <= t[r[0]] <= ev["t_c"] + 0.25]
        if cand:
            i = min(cand, key=lambda i: abs(t[res[i][0]] - ev["t_c"]))
            used.add(i)
            if ev["cls"] is None:
                continue
            a, c, conf, f = res[i]
            rows.append(dict(cls=ev["cls"], pred=c, conf=conf, dt=float(t[a] - ev["t_c"]), info=ev["info"],
                             f={k: v for k, v in f.items() if isinstance(v, (int, float))}))
        elif ev["cls"] is not None:
            rows.append(dict(cls=ev["cls"], pred=MISSED, conf=0, dt=None, info=ev["info"], f={}))
    extra = [float(t[r[0]]) for i, r in enumerate(res) if i not in used and t[r[0]] > s["extra_from"]]
    return rows, len(extra)


def evaluate(pool, st, pname):
    out = pool.map(eval_stream, [(s, pname) for s in st], chunksize=2)
    rows = [r for o in out for r in o[0]]
    return rows, sum(o[1] for o in out)


def score(rows, extras) -> dict:
    labels = CLS + [MISSED]
    cm = np.zeros((len(CLS), len(labels)), dtype=int)
    for r in rows:
        cm[CLS.index(r["cls"]), labels.index(r["pred"])] += 1
    per = {NAMES[c]: cm[i, i] / max(cm[i].sum(), 1) for i, c in enumerate(CLS) if cm[i].sum()}
    tot = sum(cm[i, i] for i in range(len(CLS))) / max(cm.sum(), 1)
    cw = sum(1 for r in rows if r["pred"] not in (MISSED, r["cls"]) and r["conf"] >= CONF_THR)
    return {"overall": float(tot), "per_class": per, "worst": min(per.values()), "cm": cm.tolist(),
            "missed": int(cm[:, -1].sum()), "extras": int(extras), "confident_wrong": cw, "n": len(rows)}


def print_cm(s: dict, title: str) -> None:
    hdr = [NAMES[c][:8] for c in CLS] + ["missed"]
    print(f"\n{title}: acc {s['overall']:.3f}, worst {s['worst']:.3f}, missed {s['missed']}, "
          f"extra {s['extras']}, conf-wrong {s['confident_wrong']} / {s['n']}")
    print(f"{'true \\ pred':>12} " + " ".join(f"{h:>8}" for h in hdr) + "    acc")
    for i, c in enumerate(CLS):
        row = s["cm"][i]
        if sum(row):
            print(f"{NAMES[c]:>12} " + " ".join(f"{x:8d}" for x in row) + f"  {s['per_class'][NAMES[c]]:.3f}")


def summary_line(name, s):
    per = " ".join(f"{k[:5]} {v * 100:5.1f}" for k, v in s["per_class"].items())
    return (f"{name:>14} acc {s['overall'] * 100:5.1f}  miss {s['missed']:4d}  extra {s['extras']:4d}  "
            f"cwrong {s['confident_wrong']:4d}  n {s['n']:5d} | {per}")


# ---- author-simulator knob sweep (unchanged method) ------------------------------------

SWEEPS = {
    "acc_bias_g":      ("±0.05", [0.0, 0.05, 0.1, 0.2, 0.3]),
    "gyro_bias_dps":   ("±3", [0.0, 3.0, 6.0, 12.0, 24.0]),
    "tilt_static_deg": ("±5", [0.0, 5.0, 10.0, 15.0, 20.0]),
    "tilt_dyn_deg":    ("±5", [0.0, 5.0, 10.0, 15.0, 20.0]),
    "heading_deg":     ("±20", [0.0, 10.0, 20.0, 30.0, 40.0]),
    "crosstalk_g":     ("0–0.6", [0.0, 0.6, 1.2, 2.0]),
    "gap_min_s":       ("≥0.06 s", [0.03, 0.06, 0.1, 0.2]),
    "land_speed":      ("×1", [0.0, 1.0, 2.0, 3.0]),
    "tempo":           ("70–140 bpm", [55, 70, 100, 140, 160, 180]),
    "step_size":       ("×0.55–1.15", [0.3, 0.4, 0.55, 0.8, 1.15]),
    "soft_share":      ("15% (+lazy)", [0.0, 0.15, 0.5, 1.0]),
    "kick_angle":      ("30–80°", [20.0, 25.0, 30.0, 45.0, 80.0]),
    "toe_out":         ("in heading", [0.0, 10.0, 20.0, 30.0]),
}


def realism_for(knob: str, v) -> F.Realism:
    R = F.Realism()
    special = {"tempo": dict(tempo_bpm=(v, v)), "step_size": dict(lazy_p=1.0, lazy_scale=(v, v)),
               "soft_share": dict(p_soft=v), "kick_angle": dict(kick_angle_deg=(v, v)),
               "toe_out": dict(toe_out_deg=(v, v)), "land_speed": dict(land_speed=v)}
    if knob in special:
        return replace(R, **special[knob])
    return replace(R, edge=frozenset([knob]), **{knob: v})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=0, help="author: trials per class; auditor/stress: routines")
    ap.add_argument("--seed", type=int, default=1, help="1 = dev; use another for a held-out check")
    ap.add_argument("--sets", default="author,auditor,stress")
    ap.add_argument("--pipes", default="old,new")
    ap.add_argument("--sweep", default="", help="comma list of author-sim knobs, or 'all'")
    ap.add_argument("--cm", action="store_true", help="print confusion matrices")
    ap.add_argument("--json", default="")
    ap.add_argument("--procs", type=int, default=os.cpu_count())
    a = ap.parse_args()
    pipes = a.pipes.split(",")
    report = {}
    with Pool(a.procs) as pool:
        if a.sweep:
            knobs = list(SWEEPS) if a.sweep == "all" else a.sweep.split(",")
            n = a.n or 60
            for knob in knobs:
                for v in SWEEPS[knob][1]:
                    res = pool.map(gen_trial, jobs_author(n, a.seed, realism_for(knob, v)), chunksize=4)
                    st = [s for r in res for s in r]
                    for p in pipes:
                        sc = score(*evaluate(pool, st, p))
                        report.setdefault(knob, []).append({"value": v, "pipe": p, **sc})
                        print(summary_line(f"{knob}={v} {p}", sc), flush=True)
        else:
            pooled = {p: ([], 0) for p in pipes}
            for name in a.sets.split(","):
                n = a.n or {"author": 60, "auditor": 40, "stress": 42}.get(name, 30)
                st = streams(pool, name, n, a.seed)
                for p in pipes:
                    rows, ex = evaluate(pool, st, p)
                    sc = score(rows, ex)
                    report[f"{name}/{p}"] = sc
                    pooled[p] = (pooled[p][0] + rows, pooled[p][1] + ex)
                    print(summary_line(f"{name} {p}", sc), flush=True)
                    if a.cm:
                        print_cm(sc, f"{name} {p}")
            if len(a.sets.split(",")) > 1:
                for p in pipes:
                    sc = score(*pooled[p])
                    report[f"mixed/{p}"] = sc
                    print(summary_line(f"mixed {p}", sc))
                    if a.cm:
                        print_cm(sc, f"mixed {p}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1, default=float)


if __name__ == "__main__":
    main()
