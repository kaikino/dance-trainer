#!/usr/bin/env python3
"""Two-node cross vs side_in on both simulators (dt/twonode.py), against the single-node rule.

Sets (same streams as realsim.py, cached in runs/simcache/):
  author   dt/footsim.py cross and side_in trials (other foot rebuilt, see twonode.py)
  auditor  dt/legsim.py routines, realistic settings (calibration stance 10-30 cm)
  stress   dt/legsim.py routines, one condition at the edge each (incl. calnarrow/calwide/calhip)
  calhip   dt/legsim.py routines calibrated in the documented hip-width stance

Scored on the steps where it matters: true cross or side_in, a window cut, and the
single-node rule put it in the inward sector (pred cross or side_in), i.e. the
cases the override could change. "e2e" = per-class accuracy over all true cross /
side_in steps, as realsim.py counts it (missed and other classes are wrong).

Thresholds are fitted on seed 1 (author + auditor pooled) and applied unchanged
to every set and to seed 2 (held out).

Usage: twonode_eval.py [--seeds 1,2] [--n-aud 40] [--n-calhip 40]
"""
import argparse
import os
import pickle
from multiprocessing import Pool

import numpy as np

import realsim as RS
from dt import twonode as TN
from dt.protocol import StepClass

CACHE = RS.CACHE


def rows_for(pool, name, seed, n):
    p = CACHE / f"twonode_{name}_n{n}_s{seed}.pkl"
    if p.exists():
        return pickle.loads(p.read_bytes())
    if name == "author":
        jobs = [j for j in RS.jobs_author(n, seed) if j[0] in TN.INWARD]
        out = pool.map(TN.footsim_trial, jobs, chunksize=2)
    else:
        if name == "calhip":
            CACHE.mkdir(parents=True, exist_ok=True)
            sp = CACHE / f"calhip_n{n}_s{seed}.pkl"
            if sp.exists():
                st = pickle.loads(sp.read_bytes())
            else:
                jobs = [(seed * 100003 + 1000 * i + 31, {**RS.AUD_REAL, "cal_w": "hip"}, {}, "calhip") for i in range(n)]
                st = [s for r in pool.map(RS.gen_routine, jobs, chunksize=1) for s in r]
                sp.write_bytes(pickle.dumps(st))
        else:
            st = RS.streams(pool, name, n, seed)
        pairs = [(st[i], st[i + 1]) for i in range(0, len(st), 2)]
        out = pool.map(TN.legsim_pair, pairs, chunksize=1)
    rows = [r for o in out for r in o]
    p.write_bytes(pickle.dumps(rows))
    return rows


def acc(rows, fn):
    """(cross acc, side_in acc, balanced) of fn(row) -> class over rows."""
    c = [fn(r) == r["cls"] for r in rows if r["cls"] == TN.CROSS]
    s = [fn(r) == r["cls"] for r in rows if r["cls"] == TN.SIDE_IN]
    a = np.mean(c) if c else np.nan; b = np.mean(s) if s else np.nan
    return a, b, np.nanmean([a, b]), len(c), len(s)


def fmt(t):
    return f"cross {t[0]*100:5.1f}  close {t[1]*100:5.1f}  bal {t[2]*100:5.1f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", default="1,2")
    ap.add_argument("--n-aud", type=int, default=40)
    ap.add_argument("--n-calhip", type=int, default=40)
    a = ap.parse_args()
    seeds = [int(s) for s in a.seeds.split(",")]
    sets = {"author": 60, "auditor": a.n_aud, "stress": 42, "calhip": a.n_calhip}
    R = {}
    with Pool(os.cpu_count()) as pool:
        for sd in seeds:
            for name, n in sets.items():
                R[(name, sd)] = rows_for(pool, name, sd, n)
                print(f"{name} s{sd}: {len(R[(name, sd)])} rows", flush=True)

    inw = lambda rows: [r for r in rows if r["pred"] in TN.INWARD]

    # sanity: truth separation
    print("\nTruth ankle separation after the step (cm, + = feet on their own sides):")
    for (name, sd), rows in R.items():
        if sd != seeds[0]:
            continue
        for c in TN.INWARD:
            v = [r["sep"] for r in rows if r["cls"] == c and "sep" in r]
            print(f"  {name:8} {StepClass(c).name.lower():8} min {min(v):6.1f}  median {np.median(v):6.1f}  max {max(v):6.1f}")

    # thresholds on seed 1, author + auditor
    dev = inw(R[("author", 1)]) + inw(R[("auditor", 1)])
    TH = {f: TN.best_threshold(dev, f) for f in TN.FEATS}
    TH["roll"] = -5.0      # the shipped rule
    TH_fit_roll = TN.best_threshold(dev, "roll")
    print("\nthresholds (th, sign: cross if sign*x <= sign*th), fitted on seed 1 author+auditor:",
          TH, f"(single-node roll refit: {TH_fit_roll})")

    def policies():
        yield "single (rules.c)", lambda r: r["pred"]
        yield f"single roll refit {TH_fit_roll[0]:.1f}", lambda r: TN.call(r, "roll", TH_fit_roll)
        for f in ("roll_other", "roll_diff", "roll_sum", "roll_sum_still", "dr_sep"):
            yield f"{f} {'<=' if TH[f][1] > 0 else '>'} {TH[f][0]:.1f}", (lambda f: lambda r: TN.call(r, f, TH[f]))(f)
        yield "override roll_sum if conf<160", lambda r: r["pred"] if r["conf"] >= 160 else TN.call(r, "roll_sum", TH["roll_sum"])
        yield "override roll_sum_still if conf<160", lambda r: r["pred"] if r["conf"] >= 160 else TN.call(r, "roll_sum_still", TH["roll_sum_still"])
        yield "override dr_sep if conf<160", lambda r: r["pred"] if r["conf"] >= 160 else TN.call(r, "dr_sep", TH["dr_sep"])

    print("\nInward-sector steps (true cross/side_in, single node said cross or side_in):")
    for (name, sd), rows in R.items():
        rr = inw(rows)
        nc = sum(r["cls"] == TN.CROSS for r in rr); ns = len(rr) - nc
        nst = sum(r["roll_other_still"] is not None for r in rr)
        print(f"\n  {name} seed {sd}{' (held out)' if sd != 1 else ''}: {nc} cross, {ns} side_in; other node still nearby: {nst}/{len(rr)}")
        for lab, fn in policies():
            print(f"    {lab:34} {fmt(acc(rr, fn))}")
        # per-set oracle threshold (ceiling of the feature on this set)
        for f in ("roll", "roll_sum", "roll_sum_still", "dr_sep"):
            th = TN.best_threshold(rr, f)
            print(f"    {'(oracle ' + f + ' ' + format(th[0], '.1f') + ')':34} {fmt(acc(rr, lambda r: TN.call(r, f, th)))}")

    # end to end per class, as realsim counts it
    print("\nEnd to end (all true cross / side_in steps; missed or other class = wrong):")
    for (name, sd), rows in R.items():
        b = acc(rows, lambda r: r["pred"])
        t = acc(rows, lambda r: TN.call(r, "roll_sum_still", TH["roll_sum_still"]) if r["pred"] in TN.INWARD else r["pred"])
        print(f"  {name:8} s{sd}  single: {fmt(b)}   +roll_sum_still: {fmt(t)}")

    # calibration stance (legsim auditor + stress, both seeds)
    print("\nBy calibration stance width (legsim auditor+stress+calhip, both seeds), balanced acc:")
    lr = [r for (name, sd), rows in R.items() if name != "author" for r in inw(rows)]
    for lo, hi in [(0.0, 0.08), (0.08, 0.14), (0.14, 0.20), (0.20, 0.26), (0.26, 0.40)]:
        sub = [r for r in lr if lo <= r["info"]["cal_w"] < hi]
        if len(sub) < 10:
            continue
        print(f"  cal_w {lo*100:3.0f}-{hi*100:3.0f} cm n={len(sub):4d}  single {acc(sub, lambda r: r['pred'])[2]*100:5.1f}"
              f"  roll_sum {acc(sub, lambda r: TN.call(r, 'roll_sum', TH['roll_sum']))[2]*100:5.1f}"
              f"  roll_sum_still {acc(sub, lambda r: TN.call(r, 'roll_sum_still', TH['roll_sum_still']))[2]*100:5.1f}"
              f"  dr_sep {acc(sub, lambda r: TN.call(r, 'dr_sep', TH['dr_sep']))[2]*100:5.1f}")
    print("\nBy stress condition (both seeds), balanced acc single / roll_sum_still / dr_sep:")
    for k in RS.STRESS:
        sub = [r for (name, sd), rows in R.items() if name == "stress" for r in inw(rows) if r["info"]["tag"] == k]
        if sub:
            print(f"  {k:10} n={len(sub):3d}  {acc(sub, lambda r: r['pred'])[2]*100:5.1f} / "
                  f"{acc(sub, lambda r: TN.call(r, 'roll_sum_still', TH['roll_sum_still']))[2]*100:5.1f} / "
                  f"{acc(sub, lambda r: TN.call(r, 'dr_sep', TH['dr_sep']))[2]*100:5.1f}")

    # dead-reckoning drift
    print("\nDead-reckoned separation error (cm) vs windows since the start (legsim, both seeds):")
    for lo, hi in [(0, 4), (4, 8), (8, 14), (14, 40)]:
        e = [r["dr_sep"] - r["sep"] for r in lr if lo <= r["n_prior"] < hi]
        if e:
            print(f"  {lo:2d}-{hi:2d} windows: n={len(e):4d}  mean {np.mean(e):6.1f}  sd {np.std(e):5.1f}  |e|>5: {np.mean(np.abs(np.array(e))>5)*100:4.0f}%")
    e = [r["dr_sep"] - r["sep"] for (name, sd), rows in R.items() if name == "author" for r in inw(rows)]
    print(f"  footsim (true start, 2 steps): sd {np.std(e):.1f}, mean {np.mean(e):.1f}")
    # roll_sum as a separation estimate
    for sim in ("legsim", "footsim"):
        rr = [r for rows in R.values() for r in inw(rows) if r["sim"] == sim]
        rr = [r for r in rr if r["roll_other_still"] is not None]
        x = np.array([r["roll"] + r["roll_other_still"] for r in rr]); y = np.array([r["sep"] for r in rr])
        k, c = np.polyfit(x, y, 1); res = y - (k * x + c)
        print(f"  {sim}: sep ~ {k:.2f} cm/deg * roll_sum + {c:.1f}; residual sd {res.std():.1f} cm, r={np.corrcoef(x, y)[0,1]:.2f}")


if __name__ == "__main__":
    main()
