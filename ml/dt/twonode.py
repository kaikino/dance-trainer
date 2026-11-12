"""Two-node cross vs side_in: does the other ankle settle what one shank roll cannot?

A cross ends with the feet swapped (ankle separation < 0), a close (side_in) with
them a few cm apart. One node sees only its own shank roll after landing, which a
weight shift moves as much as the step does. With both nodes the app could use:

  roll_sum   own roll + the other node's roll over the same samples (both
             negative = inward). Shank roll ~ (hip - ankle) lateral / leg length,
             so the sum tracks ankle separation - hip width; a pelvis shift tilts
             both legs the same way and cancels in the sum.
  roll_diff  own - other.
  roll_other the other node's roll alone.
  dr_sep     dead-reckoned separation: the start stance plus every detected
             step's lateral displacement (dy, outward, both feet) since then.

Simulators:
  legsim   two-leg routines; both nodes are simulated in the same body, so the
           other roll and every step's dy come from the firmware pipeline on the
           other stream. Truth separation from the planned ankle positions.
  footsim  one foot; the other foot stands still at y=0 (it is never simulated
           as an IMU). Its shank is rebuilt from the same pelvis/hip geometry
           (debug output), with calibration tilt and accel bias drawn from the
           same Realism ranges as the target node's. dr_sep there has the true
           start (the trial has no routine before it): best case.

Rows carry the single-node call (class, conf) so the override policy (two-node
call only when conf < 160) can be scored.
"""
import math

import numpy as np

from . import baseline, node
from . import footsim as F
from .protocol import StepClass

CROSS, SIDE_IN = int(StepClass.CROSS), int(StepClass.SIDE_IN)
INWARD = (CROSS, SIDE_IN)
ROLL_N = baseline.ROLL_SAMPLES
LEG_START_SEP_CM = 16.0          # legsim.plan_routine starts the feet at y = ±0.08 m


def _pipe(fused, right):
    det = node.NEW_DETECTOR
    out = []
    for a in node.detect_swing(fused, det):
        w = node.cut(fused, a, right, det.win_pre, det.win_post)
        f = baseline.features(w)
        c, conf = baseline.decide(f)
        out.append(dict(a=a, cls=int(c), conf=int(conf), dy=f["dy_cm"], dx=f["dx_cm"], roll=f["roll_deg"],
                        e_abs=a - det.win_pre + f["e"]))
    return out


def _match(res, events, t):
    """realsim.eval_stream matching: event index -> res index (or None)."""
    used = set(); m = {}
    for k, ev in sorted(enumerate(events), key=lambda kv: kv[1]["t_c"]):
        cand = [i for i, r in enumerate(res) if i not in used and ev["lo"] <= t[r["a"]] <= ev["t_c"] + 0.25]
        if cand:
            i = min(cand, key=lambda i: abs(t[res[i]["a"]] - ev["t_c"]))
            used.add(i); m[k] = i
    return m


STILL_DPS = 40.0      # the other node counts as standing still: |gyro| below this ...
STILL_G = 0.08        # ... and ||a| - 1 g| below this, for ROLL_N samples


def roll_still(acc: np.ndarray, gyr: np.ndarray, i0: int, right: bool, back: int = 52, fwd: int = 26):
    """The other node's roll over the still ROLL_N-sample block nearest to i0 (searching
    back `back` and forward `fwd` samples), or None if it never stood still there.
    On the node: the roll of its latest still moment, sent on request or with each event."""
    n = len(acc)
    g = np.linalg.norm(gyr, axis=1); a = np.abs(np.linalg.norm(acc, axis=1) - 1)
    ok = (g < STILL_DPS) & (a < STILL_G)
    best = None
    for d in range(0, max(back, fwd) + 1):
        for j in ((i0 - d, i0 + d) if d else (i0,)):
            if j < 0 or j + ROLL_N > n or j < i0 - back or j > i0 + fwd:
                continue
            if ok[j:j + ROLL_N].all():
                best = j
                break
        if best is not None:
            break
    return None if best is None else roll_at(acc, best, right)


def roll_at(acc: np.ndarray, i0: int, right: bool) -> float:
    """Shank roll (deg, - = inward) from raw accel over ROLL_N samples, as rules.c does."""
    seg = acc[max(i0, 0):max(i0, 0) + ROLL_N]
    ay = seg[:, 1].sum() * (-1 if right else 1); az = seg[:, 2].sum()
    return math.degrees(math.atan2(ay, az))


# ---- legsim (cached realsim streams: [L, R] per routine) ---------------------------------

def legsim_pair(args):
    sL, sR = args
    assert not sL["right"] and sR["right"]
    t = sL["fused"]["t"]
    S = {0: sL, 1: sR}
    res = {k: _pipe(S[k]["fused"], S[k]["right"]) for k in S}
    match = {k: _match(res[k], S[k]["events"], t) for k in S}
    # truth separation after each step (both feet, time order)
    allev = sorted([(ev["t_c"], k, j) for k in S for j, ev in enumerate(S[k]["events"])])
    sep = LEG_START_SEP_CM; sep_after = {}
    for _, k, j in allev:
        sep += S[k]["events"][j]["info"]["tdy"]
        sep_after[(k, j)] = sep
    # dead reckoning: every window of both nodes, in time order
    wins = sorted([(r["a"], k, i) for k in S for i, r in enumerate(res[k])])
    rows = []
    for k in S:
        o = 1 - k
        for j, ev in enumerate(S[k]["events"]):
            if ev["cls"] not in INWARD:
                continue
            i = match[k].get(j)
            if i is None:
                rows.append(dict(cls=ev["cls"], pred=-1, sim="legsim", info=ev["info"]))
                continue
            r = res[k][i]
            dr = LEG_START_SEP_CM + sum(res[kk][ii]["dy"] for a, kk, ii in wins if a <= r["a"])
            n_prior = sum(1 for a, _, _ in wins if a <= r["a"])
            ro = roll_at(S[o]["fused"]["acc"], r["e_abs"], S[o]["right"])
            ros = roll_still(S[o]["fused"]["acc"], S[o]["fused"]["gyr"], r["e_abs"], S[o]["right"])
            rows.append(dict(cls=ev["cls"], pred=r["cls"], conf=r["conf"], sim="legsim", info=ev["info"],
                             roll=r["roll"], roll_other=ro, roll_other_still=ros, dy=r["dy"], dr_sep=dr,
                             n_prior=n_prior,
                             sep=sep_after[(k, j)]))
    return rows


# ---- footsim (other foot rebuilt from the trial's pelvis) --------------------------------

def _other_roll_footsim(dbg, idx, rng, R):
    """Roll of the standing (other) shank, - = inward, at world sample indices idx."""
    ankle = np.array([dbg["other"][0], 0.0, dbg["ha"]])
    hip = np.concatenate([dbg["pel"][idx] - np.array([0.0, dbg["hip_half"]]),
                          np.full((len(idx), 1), dbg["hip_h"])], 1)
    z = hip - ankle; z /= np.linalg.norm(z, axis=1)[:, None]
    out = np.array([0.0, -1.0, 0.0])                       # the other foot's outward is -y
    y = out - (z @ out)[:, None] * z; y /= np.linalg.norm(y, axis=1)[:, None]
    up = np.array([0.0, 0.0, 1.0])
    roll = np.degrees(np.arctan2(y @ up, z @ up)).mean()
    # calibration tilt (lateral share of a tilt up to cal_tilt_deg) and accel y bias, as the target node
    tilt = rng.uniform(0, R.cal_tilt_deg) * math.cos(rng.uniform(0, 2 * math.pi))
    bias = math.degrees(math.atan(rng.uniform(-R.acc_bias_g, R.acc_bias_g)))
    return float(roll + tilt + bias)


def footsim_trial(args):
    cls, seed, foot, R = args
    rng = np.random.default_rng(seed)
    tr = F.simulate(StepClass(cls), rng, R, foot=foot, debug=True)
    dbg = tr.truth["debug"]
    fu = tr.fused; t = fu["t"]
    res = _pipe(fu, foot == "R")
    evs = [dict(t_c=tr.t_prev_contact, lo=tr.t_prev_contact - 0.15),
           dict(t_c=tr.t_contact, lo=tr.t_contact - 0.15)]
    m = _match(res, evs, t)
    info = dict(tag="author", seed=seed)
    if 1 not in m:
        return [dict(cls=cls, pred=-1, sim="footsim", info=info)]
    r = res[m[1]]
    i0 = r["e_abs"]
    idx = np.minimum(np.round(t[i0:i0 + ROLL_N] * F.FS).astype(int), len(dbg["t"]) - 1)
    ro = _other_roll_footsim(dbg, idx, np.random.default_rng(seed + 991), R)
    start = float((dbg["ankle"][0, 1]) * 100)          # this ankle's y before the previous step (other at 0)
    dr = start + r["dy"] + (res[m[0]]["dy"] if 0 in m else 0.0)
    sep = float(dbg["ankle"][-1, 1] * 100)
    return [dict(cls=cls, pred=r["cls"], conf=r["conf"], sim="footsim", info=info, roll=r["roll"],
                 roll_other=ro, roll_other_still=ro, dy=r["dy"], dr_sep=dr, n_prior=2, sep=sep)]


# ---- decisions ----------------------------------------------------------------------------

FEATS = {
    "roll":       lambda r: r["roll"],                     # single node (rules.c: cross if <= -5)
    "roll_other": lambda r: r["roll_other"],
    "roll_sum":   lambda r: r["roll"] + r["roll_other"],
    "roll_diff":  lambda r: r["roll"] - r["roll_other"],
    # other node's roll from its nearest still moment (falls back to the single node's
    # own roll on the -5 deg scale when the other foot never stood still nearby)
    "roll_sum_still": lambda r: r["roll"] + (r["roll_other_still"] if r["roll_other_still"] is not None
                                             else r["roll"]),
    "dr_sep":     lambda r: r["dr_sep"],
}


def best_threshold(rows, feat):
    """(th, sign) maximising balanced accuracy of 'cross if sign*x <= sign*th'."""
    xs = np.array([FEATS[feat](r) for r in rows]); y = np.array([r["cls"] == CROSS for r in rows])
    best = (0, 0.0, 1)
    for sign in (+1, -1):
        for th in np.unique(np.round(xs, 1)):
            p = sign * xs <= sign * th
            bal = 0.5 * ((p & y).sum() / max(y.sum(), 1) + (~p & ~y).sum() / max((~y).sum(), 1))
            if bal > best[0]:
                best = (bal, float(th), sign)
    return best[1], best[2]


def call(r, feat, th):
    """th: (threshold, sign) from best_threshold, or a threshold (cross if x <= th)."""
    th, sign = th if isinstance(th, tuple) else (th, 1)
    return CROSS if sign * FEATS[feat](r) <= sign * th else SIDE_IN
