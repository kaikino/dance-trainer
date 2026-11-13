"""Independent two-leg dance-step generator (auditor's model).

Modelling choices (deliberately different from the project's simulator, which I have not read):
- Whole body: pelvis centre trajectory (weight shifts as superposed min-jerk moves), hip joints
  at +-hip_w/2, pelvis height lowered by a soft-min so neither leg over-extends.
- Each leg: 2-link IK (thigh, shank) from hip and ankle positions; the knee bends toward the
  leg's heading (turnout + pelvis yaw + per-step rotation). Shank frame: z = ankle->knee,
  x = anterior. So shank sagittal/frontal angles in swing, stance and weight transfer come
  from geometry, not from hand-set angle curves.
- Ankle trajectory: quintic-Hermite keyframes: heel rise about the ball, swing apex, contact
  with non-zero landing velocity (heel / flat / ball contact geometry), impact deceleration
  over tau_imp (footwear), roll to foot-flat (heel rocker or heel lowering).
- Sensor: on the shank d_s above the ankle, r_off out to the side; strap/soft tissue as a
  2nd-order wobble (f_n, zeta) between bone and sensor.
- Calibration emulated: calibrated frame = shank frame at a standing pose (stance width,
  turnout) with gravity -> +z and a yaw error on the slide direction. Mount rotation cancels.
- Simulated at 1040 Hz, boxcar-decimated to 104 Hz, noise + residual gyro bias.

Copied from the independent audit of the rule fallback. One change: the pelvis
height is smoothed (hz_smooth, 40 ms Gaussian); the original let it jump up to 6 cm
in 5 ms when a far foot lifted, which put one-sample 700 dps / 50 g spikes on the
standing shank. realsim.py keeps the original as the "rawpelvis" stress condition.
"""
import math
import numpy as np

FS = 1040
DEC = 10
G = 9.80665
D2R = math.pi / 180

CLASSES = ["in_place", "forward", "back", "side_out", "cross", "kick", "side_in",
           "forward_out", "forward_in", "back_out", "back_in", "cross_behind"]
# StepClass ints from protocol
from .protocol import StepClass
CLS_ID = {"in_place": StepClass.IN_PLACE, "forward": StepClass.FORWARD, "back": StepClass.BACK,
          "side_out": StepClass.SIDE_OUT, "cross": StepClass.CROSS, "kick": StepClass.KICK,
          "side_in": StepClass.SIDE_IN, "forward_out": StepClass.FORWARD_OUT,
          "forward_in": StepClass.FORWARD_IN, "back_out": StepClass.BACK_OUT, "back_in": StepClass.BACK_IN,
          "cross_behind": StepClass.CROSS_BEHIND}


def U(rng, a, b):
    return float(rng.uniform(a, b))


def mj(t, t0, t1):
    """min-jerk 0->1 over [t0,t1]"""
    s = np.clip((t - t0) / max(t1 - t0, 1e-6), 0, 1)
    return s ** 3 * (10 - 15 * s + 6 * s * s)


def hermite5(t, t0, t1, p0, p1, v0, v1):
    """quintic hermite with zero accel at both ends, vectorised over t (inside [t0,t1])."""
    T = t1 - t0
    s = ((t - t0) / T)[:, None]
    h00 = 1 - 10 * s**3 + 15 * s**4 - 6 * s**5
    h10 = s - 6 * s**3 + 8 * s**4 - 3 * s**5
    h01 = 10 * s**3 - 15 * s**4 + 6 * s**5
    h11 = -4 * s**3 + 7 * s**4 - 3 * s**5
    return h00 * p0 + h10 * T * v0 + h01 * p1 + h11 * T * v1


def rot_lat(P, O, psi, th):
    """rotate point P about pivot O, axis = foot lateral axis (heading psi), by th (+ = toe down)."""
    xf = np.array([math.cos(psi), math.sin(psi), 0.0])
    yf = np.array([-math.sin(psi), math.cos(psi), 0.0])
    zf = np.array([0, 0, 1.0])
    v = P - O
    x, y, z = v @ xf, v @ yf, v @ zf
    c, s = math.cos(th), math.sin(th)
    x2 = c * x + s * z
    z2 = -s * x + c * z
    return O + x2 * xf + y * yf + z2 * zf


class Dancer:
    def __init__(self, rng, over=None):
        o = over or {}
        self.H = o.get("height", U(rng, 1.55, 1.92))
        H = self.H
        self.Lt = 0.245 * H; self.Ls = 0.246 * H
        self.ha = 0.039 * H                       # ankle height
        self.lfore = U(rng, 0.075, 0.09) * H      # ankle -> ball of foot (horizontal)
        self.lheel = 0.03 * H
        self.hipw = U(rng, 0.09, 0.11) * H        # hip joint centre separation
        self.kneeflex = o.get("kneeflex", U(rng, 6, 22))   # standing knee flexion, deg
        self.turnout = o.get("turnout", U(rng, 0, 25))     # deg per leg
        self.d_s = o.get("d_s", U(rng, 0.06, 0.12))        # sensor height above ankle joint along shank
        self.r_off = o.get("r_off", U(rng, 0.03, 0.055))
        cw = o.get("cal_w", (0.10, 0.30))                  # stance width at calibration (centre-centre):
        if cw == "hip":                                    # "feet under the hips" (bench-check.md), ±1.5 cm
            self.cal_w = self.hipw + float(rng.normal(0, 0.015))
        elif isinstance(cw, tuple):
            self.cal_w = U(rng, *cw)
        else:
            self.cal_w = cw
        self.cal_yaw_err = o.get("cal_yaw_err", rng.normal(0, 6))  # deg
        self.cal_tilt_err = o.get("cal_tilt_err", rng.normal(0, 1.0))
        foot = o.get("footwear", rng.choice(["socks", "sneakers", "carpet"], p=[0.3, 0.5, 0.2]))
        self.footwear = foot
        self.tau_imp = {"socks": (0.008, 0.018), "sneakers": (0.018, 0.035), "carpet": (0.03, 0.05)}[foot]
        self.wob_f = o.get("wob_f", U(rng, 15, 35))
        self.wob_z = o.get("wob_z", U(rng, 0.3, 0.6))
        self.v_land = o.get("v_land", (0.08, 0.5))
        self.p_land = o.get("p_land", None)       # landing-type mix override
        self.p_slide = o.get("p_slide", 0.15)
        self.lift = o.get("lift", (0.02, 0.12))
        self.step_scale = o.get("step_scale", 1.0)
        self.extra_rot = o.get("extra_rot", 15.0)  # per-step leg rotation spread for crosses, deg
        self.pelvis_yaw = o.get("pelvis_yaw", 12.0)
        self.shift_lead = o.get("shift_lead", (0.0, 0.0))
        self.kick_phi = o.get("kick_phi", (25, 85))   # hip flexion at kick apex, deg
        self.beta = o.get("beta", (0.4, 0.95))    # weight transfer fraction
        self.hz_smooth = o.get("hz_smooth", 0.04)  # s; 0 = the auditor's original (pelvis pops)
        self.gyro_bias = rng.uniform(-1.5, 1.5, size=(2, 3))
        L = self.Lt + self.Ls
        k = self.kneeflex * D2R
        self.D0 = math.sqrt(self.Lt**2 + self.Ls**2 + 2 * self.Lt * self.Ls * math.cos(k))
        self.hip_nom = self.ha + math.sqrt(self.D0**2 - (0.0)**2)


def plan_routine(rng, dz: Dancer, n_steps, bpm, eighth, classes=None, cls_p=None):
    """Random but physically consistent step sequence. Returns list of step dicts."""
    dt_beat = 60.0 / bpm / (2 if eighth else 1)
    feet = {+1: np.array([0.0, 0.08, dz.ha]), -1: np.array([0.0, -0.08, dz.ha])}  # +1 = left
    steps = []
    t = 1.6
    foot = +1
    last_contact = {+1: 0.0, -1: 0.0}
    last_any = 0.0
    pool = classes or CLASSES
    for k in range(n_steps):
        o = foot
        P0 = feet[o].copy(); Q = feet[-o].copy()
        sep = (P0[1] - Q[1]) * o          # lateral separation, + = this foot outward
        feas = []
        for c in pool:
            if c == "side_in" and sep < 0.24: continue
            if c == "side_out" and sep > 0.42: continue
            if c == "forward" and P0[0] - Q[0] > 0.15: continue
            if c == "back" and P0[0] - Q[0] < -0.15: continue
            if c in ("cross", "cross_behind") and sep < 0.06: continue
            if c.endswith("_out") and c != "side_out" and sep > 0.42: continue
            if c.endswith("_in") and c != "side_in" and sep < 0.20: continue
            if c.startswith("forward_") and P0[0] - Q[0] > 0.15: continue
            if c.startswith("back_") and P0[0] - Q[0] < -0.15: continue
            feas.append(c)
        if not feas:
            feas = ["side_in"] if sep >= 0.24 else ["in_place"]
        if cls_p is None:
            cls_p = {"in_place": 1, "forward": 1, "back": 1, "side_out": 1, "cross": 1, "kick": 0.8, "side_in": 3,
                     "forward_out": 0.8, "forward_in": 1.5, "back_out": 0.8, "back_in": 1.5, "cross_behind": 1}
        if cls_p is not None:
            p = np.array([cls_p.get(c, 0) for c in feas], float)
            if p.sum() == 0: feas = feas; p = None
            else: p = p / p.sum()
        else:
            p = None
        c = str(rng.choice(feas, p=p))
        sc = dz.step_scale
        lazy = rng.random() < 0.2
        L = (U(rng, 0.10, 0.17) if lazy else U(rng, 0.17, 0.42)) * sc
        P1 = P0.copy()
        bulge = np.zeros(3)
        if c == "in_place":
            P1[:2] += rng.normal(0, 0.012, 2)
        elif c == "forward":
            P1[0] += L; P1[1] += rng.normal(0, 0.03)
        elif c == "back":
            P1[0] -= L * 0.9; P1[1] += rng.normal(0, 0.03)
        elif c == "side_out":
            L = min(L, max(0.10, 0.48 - sep)); P1[1] += o * L; P1[0] += rng.normal(0, 0.03)
        elif c == "side_in":
            P1[1] = Q[1] + o * U(rng, 0.08, 0.16); P1[0] = Q[0] + rng.normal(0, 0.03)
        elif c in ("forward_out", "back_out"):
            sx = 1 if c == "forward_out" else -0.9
            Ly = min(L * U(rng, 0.5, 0.75), max(0.08, 0.48 - sep))
            P1[1] += o * Ly; P1[0] += sx * Ly * U(rng, 0.7, 1.4)
        elif c in ("forward_in", "back_in"):
            sx = 1 if c == "forward_in" else -0.9
            P1[1] = Q[1] + o * U(rng, 0.08, 0.16)
            P1[0] += sx * abs(P1[1] - P0[1]) * U(rng, 0.7, 1.4)
        elif c in ("cross", "cross_behind"):
            front = c == "cross"
            P1[1] = Q[1] - o * U(rng, -0.01, 0.13)
            P1[0] = Q[0] + (1 if front else -1) * U(rng, 0.07, 0.20)
            bulge[0] = (1 if front else -1) * U(rng, 0.0, 0.06)
        elif c == "kick":
            P1[:2] += rng.normal(0, 0.03, 2)
        slide = c in ("side_in", "in_place", "forward", "back", "side_out",
                      "forward_out", "forward_in", "back_out", "back_in") and rng.random() < (
            dz.p_slide * (2 if c == "side_in" else 1)) and c != "in_place"
        # timing
        beats = 2 if c == "kick" else 1
        t_c = t + dt_beat * beats
        free = t_c - max(last_contact[o] + 0.06, last_any + 0.02)
        if c == "kick":
            T_sw = min(U(rng, 0.40, 0.85), free)
        else:
            T_sw = min(U(rng, 0.20, 0.50), U(rng, 0.75, 0.95) * free)
        T_sw = max(T_sw, 0.13)
        # landing type
        if dz.p_land:
            lt = str(rng.choice(list(dz.p_land), p=list(dz.p_land.values())))
        elif c in ("forward", "forward_out", "forward_in"):
            lt = str(rng.choice(["heel", "flat", "ball"], p=[0.45, 0.3, 0.25]))
        elif c in ("back", "cross", "back_out", "back_in", "cross_behind"):
            lt = str(rng.choice(["flat", "ball"], p=[0.3, 0.7]))
        elif c == "kick":
            lt = str(rng.choice(["flat", "ball"], p=[0.5, 0.5]))
        else:
            lt = str(rng.choice(["heel", "flat", "ball"], p=[0.1, 0.5, 0.4]))
        if slide:
            lt = "flat"
        st = dict(k=k, foot=o, cls=c, P0=P0, P1=P1, Q=Q, t_c=t_c, T_sw=T_sw, slide=slide, land=lt,
                  lift=U(rng, *dz.lift) * (0.6 if lazy else 1), bulge=bulge,
                  v_land=U(rng, *dz.v_land), v_h=U(rng, 0.0, 0.35),
                  tau_imp=U(rng, *dz.tau_imp), heel_rise=0 if (slide or c.startswith("back")) else U(rng, 0, 25) * D2R,
                  land_ang=(U(rng, 5, 15) if lt == "heel" else U(rng, 10, 30) if lt == "ball" else 0) * D2R,
                  tau_roll=U(rng, 0.05, 0.14),
                  stay_ball=(lt == "ball" and rng.random() < 0.25),
                  beta=(U(rng, 0.0, 0.15) if c == "kick" else U(rng, 0.0, 0.7) if c == "in_place"
                        else U(rng, 0.3, 0.6) if c == "side_in" else U(rng, *dz.beta)),
                  gamma=U(rng, 0.0, 0.3), T_wt=U(rng, 0.08, 0.3),
                  pyaw=(rng.normal(0, dz.pelvis_yaw) if c.startswith("cross") else rng.normal(0, 3)),
                  lrot=(rng.normal(0, dz.extra_rot) if c.startswith("cross") else rng.normal(0, 4)),
                  kick_phi=U(rng, *dz.kick_phi) * D2R, kick_knee=U(rng, 0, 45) * D2R, kick_hold=U(rng, 0, 0.15) if rng.random() < 0.3 else 0.0)
        steps.append(st)
        feet[o] = P1
        last_contact[o] = t_c
        last_any = t_c
        t = t_c
        # next foot: alternate mostly; kicks / in_place may repeat
        if c in ("kick", "in_place") and rng.random() < 0.3:
            pass
        else:
            foot = -o
    return steps, t + 1.6


def build(rng, dz: Dancer, steps, t_end):
    n = int(t_end * FS)
    t = np.arange(n) / FS
    A = {o: np.zeros((n, 3)) for o in (+1, -1)}
    # initial positions
    first = {o: None for o in (+1, -1)}
    for st in steps:
        if first[st["foot"]] is None:
            first[st["foot"]] = st["P0"]
    for o in (+1, -1):
        if first[o] is None:
            first[o] = np.array([0.0, 0.08 * o, dz.ha])
        A[o][:] = first[o]
    # pelvis: centre (x, y), yaw; leg rotation per leg
    C = np.zeros((n, 2)); C[:, 1] = 0.0
    pyaw = np.zeros(n)
    lrot = {o: np.zeros(n) for o in (+1, -1)}
    prevC = np.array([0.0, 0.0]); prevY = 0.0; prevR = {+1: 0.0, -1: 0.0}
    bumps = []
    for st in steps:
        o = st["foot"]; P0, P1, Q = st["P0"], st["P1"], st["Q"]
        t_c = st["t_c"]; T_sw = st["T_sw"]; t_l = t_c - T_sw
        # pre-shift weight onto support foot
        tgt = Q[:2] + (P0[:2] - Q[:2]) * st["gamma"]
        dur = max(0.18, 1.9 * np.linalg.norm(tgt - prevC) / 0.5)
        lead = U(rng, *dz.shift_lead)
        C += (tgt - prevC)[None, :] * mj(t, t_l + 0.04 - lead - dur, t_l + 0.04 - lead)[:, None]; prevC = tgt
        # transfer
        tgt = Q[:2] + (P1[:2] - Q[:2]) * st["beta"]
        dur = max(0.4 * T_sw + st["T_wt"], 1.9 * np.linalg.norm(tgt - prevC) / 0.5)
        C += (tgt - prevC)[None, :] * mj(t, t_c + st["T_wt"] - dur, t_c + st["T_wt"])[:, None]; prevC = tgt
        y = st["pyaw"] * D2R
        pyaw += (y - prevY) * mj(t, t_l, t_c + 0.1); prevY = y
        r = st["lrot"] * D2R
        lrot[o] += (r - prevR[o]) * mj(t, t_l, t_c - 0.02); prevR[o] = r
        # ankle keyframes
        psi_f = 0.0  # foot heading for pivots (forward)
        kf = []
        if st["heel_rise"] > 0.02 and not st["slide"]:
            Mb = P0 + np.array([dz.lfore, 0, -dz.ha])
            Aoff = rot_lat(P0, Mb, psi_f, st["heel_rise"])
            t0 = t_l - max(0.25 * T_sw, 0.08)
            kf.append((t0, P0, np.zeros(3)))
            kf.append((t_l, Aoff, None))
        else:
            kf.append((t_l, P0, np.zeros(3)))
            Aoff = P0
        # contact geometry
        lt = st["land"]
        if lt == "heel":
            Hp = P1 + np.array([-dz.lheel, 0, -dz.ha])
            Atouch = rot_lat(P1, Hp, psi_f, -st["land_ang"])
        elif lt == "ball":
            Mb = P1 + np.array([dz.lfore, 0, -dz.ha])
            Atouch = rot_lat(P1, Mb, psi_f, st["land_ang"])
        else:
            Atouch = P1 + np.array([0, 0, 0.002])
        if st["cls"] == "kick":
            phi = st["kick_phi"]; kk = st["kick_knee"]
            Dk = math.sqrt(dz.Lt**2 + dz.Ls**2 + 2 * dz.Lt * dz.Ls * math.cos(kk))
            pc = Q[:2] + (P0[:2] - Q[:2]) * st["gamma"]
            hip = np.array([pc[0], pc[1] + o * dz.hipw / 2, dz.hip_nom - 0.02])
            apex = hip + Dk * np.array([math.sin(phi), 0, -math.cos(phi)])
            apex[2] = max(apex[2], P0[2] + 0.06)
            st["kick_h"] = float(apex[2] - P0[2]); st["kick_x"] = float(apex[0] - P0[0])
            ta = t_l + 0.45 * (T_sw - st["kick_hold"])
            kf.append((ta, apex, np.array([0, 0, 0.0])))
            if st["kick_hold"] > 0:
                kf.append((ta + st["kick_hold"], apex, np.zeros(3)))
        elif not st["slide"]:
            mid = 0.5 * (Aoff + Atouch) + np.array([0, 0, st["lift"]]) + st["bulge"]
            ta = t_l + U(rng, 0.4, 0.6) * T_sw
            kf.append((ta, mid, None))
        dirh = Atouch - Aoff; dirh[2] = 0
        nh = np.linalg.norm(dirh)
        vh = dirh / nh * min(st["v_h"], nh / T_sw) if nh > 1e-3 and st["cls"] != "kick" else np.zeros(3)
        if st["slide"]:
            kf.append((t_c, P1, np.zeros(3)))
            stop = None
        else:
            vc = vh + np.array([0, 0, -st["v_land"]])
            kf.append((t_c, Atouch, vc))
            ti = st["tau_imp"]
            A2 = Atouch + vc * ti * 0.5
            A2[2] = max(A2[2], Atouch[2] - 0.004)
            if lt == "flat":
                kf.append((t_c + ti, A2, np.zeros(3)))
                kf.append((t_c + ti + 0.03, P1, np.zeros(3)))
            else:
                tr = st["tau_roll"] if lt == "heel" else st["tau_roll"] * 1.8 * (2 if st["stay_ball"] else 1)
                vr = 0.8 * (P1 - A2) / tr
                kf.append((t_c + ti, A2, vr))
                kf.append((t_c + ti + tr, P1, np.zeros(3)))
            bumps.append((t_c, -o, st["v_land"], ti))
        # fill velocities (Catmull-Rom) where None
        for i, (tk, pk, vk) in enumerate(kf):
            if vk is None:
                tp, pp, _ = kf[i - 1]; tn, pn, _ = kf[i + 1]
                v = (pn - pp) / (tn - tp)
                cap = 1.6 * np.linalg.norm(pk - pp) / (tk - tp)
                if np.linalg.norm(v) > cap: v = v / np.linalg.norm(v) * cap
                if i == len(kf) - 1: v = np.zeros(3)
                kf[i] = (tk, pk, v)
        for (ta_, pa, va), (tb, pb, vb) in zip(kf[:-1], kf[1:]):
            m = (t >= ta_) & (t < tb)
            if m.any():
                A[o][m] = hermite5(t[m], ta_, tb, pa, pb, va, vb)
        tend = kf[-1][0]
        Pend = kf[-1][1]
        A[o][t >= tend] = Pend
        # muscles cannot make the keyframe kinks: smooth the swing (not the impact)
        i0 = max(int((kf[0][0] - 0.1) * FS), 0); i1 = min(int((t_c + 0.01) * FS), n)
        seg = A[o][i0:i1].copy()
        sig = 0.018 * FS; kx = np.arange(-int(3 * sig), int(3 * sig) + 1); gk = np.exp(-0.5 * (kx / sig) ** 2); gk /= gk.sum()
        pad = np.concatenate([np.repeat(seg[:1], len(kx), 0), seg, np.repeat(seg[-1:], len(kx), 0)])
        sm = np.stack([np.convolve(pad[:, j], gk, mode="same") for j in range(3)], 1)[len(kx):-len(kx)]
        tt = t[i0:i1]
        wgt = np.clip((t_c - 0.015 - tt) / 0.05, 0, 1)[:, None]
        if st["slide"]: wgt = np.ones_like(wgt)
        A[o][i0:i1] = wgt * sm + (1 - wgt) * seg
        st["t_lift"] = kf[0][0]
    return t, A, C, pyaw, lrot, bumps


def smin(xs, k=0.01):
    xs = np.stack(xs)
    m = xs.min(0)
    return m - k * np.log(np.exp(-(xs - m) / k).sum(0))


def leg_frames(dz, t, A, C, pyaw, lrot, o, turnout_deg=None):
    """Returns sensor bone-point position (n,3) and shank rotation (n,3,3) (columns = x,y,z axes)."""
    n = len(t)
    L = dz.Lt + dz.Ls
    # hip height: nominal, lowered so both legs stay < 0.985 L
    cons = [np.full(n, dz.hip_nom)]
    hips = {}
    for oo in (+1, -1):
        hx = C[:, 0] - math.sin(0) * 0
        hipxy = np.stack([C[:, 0] - np.sin(pyaw) * oo * dz.hipw / 2, C[:, 1] + np.cos(pyaw) * oo * dz.hipw / 2], 1)
        hips[oo] = hipxy
        hd2 = ((hipxy - A[oo][:, :2]) ** 2).sum(1)
        cons.append(A[oo][:, 2] + np.sqrt(np.maximum((0.985 * L) ** 2 - hd2, 0.05))
                    + 20 * np.maximum(A[oo][:, 2] - dz.ha - 0.015, 0))   # a lifted foot does not hold the pelvis down
    hz = smin(cons, 0.008)
    if dz.hz_smooth > 0:
        # The soft-min switches constraint in a few ms when the foot that held the pelvis
        # down lifts (the pelvis "pops" up to 6 cm in 5 ms: 700 dps, ±50 g one-sample
        # spikes on the other shank). Real hips move smoothly: zero-phase Gaussian.
        sig = dz.hz_smooth * FS
        kx = np.arange(-int(3 * sig), int(3 * sig) + 1)
        gk = np.exp(-0.5 * (kx / sig) ** 2); gk /= gk.sum()
        pad = np.concatenate([np.full(len(kx), hz[0]), hz, np.full(len(kx), hz[-1])])
        hz = np.convolve(pad, gk, mode="same")[len(kx):-len(kx)]
    Hp = np.concatenate([hips[o], hz[:, None]], 1)
    Ak = A[o]
    d = Hp - Ak
    D = np.linalg.norm(d, axis=1)
    Dmax = 0.995 * L
    over = D > Dmax
    d = d / D[:, None]
    D = np.minimum(D, Dmax)
    psi = pyaw + o * dz.turnout * D2R + lrot[o]
    u = np.stack([np.cos(psi), np.sin(psi), np.full(n, 0.6)], 1)
    u /= np.linalg.norm(u, axis=1)[:, None]
    nn = u - (u * d).sum(1)[:, None] * d
    nn /= np.linalg.norm(nn, axis=1)[:, None]
    a = (dz.Ls**2 - dz.Lt**2 + D**2) / (2 * D)
    r = np.sqrt(np.maximum(dz.Ls**2 - a**2, 0))
    K = Ak + a[:, None] * d + r[:, None] * nn
    z = K - Ak; z /= np.linalg.norm(z, axis=1)[:, None]
    x = nn - (nn * z).sum(1)[:, None] * z; x /= np.linalg.norm(x, axis=1)[:, None]
    y = np.cross(z, x)
    R = np.stack([x, y, z], 2)   # columns
    S = Ak + dz.d_s * z + o * dz.r_off * y
    return S, R


def rot_log(Rm):
    """rotation vectors of (n,3,3) matrices"""
    tr = np.clip((np.trace(Rm, axis1=1, axis2=2) - 1) / 2, -1, 1)
    ang = np.arccos(tr)
    w = np.stack([Rm[:, 2, 1] - Rm[:, 1, 2], Rm[:, 0, 2] - Rm[:, 2, 0], Rm[:, 1, 0] - Rm[:, 0, 1]], 1)
    s = np.sin(ang)
    f = np.where(s > 1e-9, ang / (2 * np.where(s > 1e-9, s, 1)), 0.5)
    return w * f[:, None]


def Rz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])


def Rx(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def calib_M(dz, o, rng):
    """Fixed rotation shank frame -> calibrated frame (from a standing pose)."""
    n = 3
    t = np.arange(n) / FS
    A = {+1: np.tile([0, dz.cal_w / 2, dz.ha], (n, 1)).astype(float),
         -1: np.tile([0, -dz.cal_w / 2, dz.ha], (n, 1)).astype(float)}
    C = np.zeros((n, 2)); py = np.zeros(n); lr = {+1: np.zeros(n), -1: np.zeros(n)}
    _, R = leg_frames(dz, t, A, C, py, lr, o)
    Rs = R[0]
    # target calibrated axes in world: z up (+ small tilt err), x = forward + yaw error
    Rt = Rz(dz.cal_yaw_err * D2R) @ Rx(dz.cal_tilt_err * D2R)
    return Rs.T @ Rt


def imu(rng, dz, t, A, C, pyaw, lrot, bumps, o):
    S, R = leg_frames(dz, t, A, C, pyaw, lrot, o)
    dt = 1 / FS
    # bone-point accel
    v = np.gradient(S, dt, axis=0)
    a_b = np.gradient(v, dt, axis=0)
    # bumps from the other foot landing (this leg is the support)
    for (tc, oo, vl, ti) in bumps:
        if oo != o: continue
        m = (t >= tc) & (t < tc + 2.5 * ti + 0.01)
        tt = (t[m] - tc) / (2.5 * ti + 0.01)
        a_b[m, 2] += 0.35 * G * (vl / 0.3) * np.sin(math.pi * tt)
    # soft-tissue wobble
    w0 = 2 * math.pi * dz.wob_f; z = dz.wob_z
    xr = np.zeros(3); vr = np.zeros(3)
    a_s = np.empty_like(a_b)
    for i in range(len(t)):
        ar = -a_b[i] - 2 * z * w0 * vr - w0 * w0 * xr
        vr = vr + ar * dt; xr = xr + vr * dt
        a_s[i] = a_b[i] + ar
    M = calib_M(dz, o, rng)
    RC = R @ M
    f = (a_s + np.array([0, 0, G])) / G
    acc = np.einsum("nji,nj->ni", RC, f)
    dR = np.einsum("nji,njk->nik", RC[:-1], RC[1:])
    w = rot_log(dR) / dt / D2R
    w = np.vstack([w, w[-1:]])
    # decimate by boxcar
    nd = len(t) // DEC
    acc = acc[:nd * DEC].reshape(nd, DEC, 3).mean(1)
    w = w[:nd * DEC].reshape(nd, DEC, 3).mean(1)
    RCd = RC[:nd * DEC:DEC]
    acc += rng.normal(0, 0.003, acc.shape)
    w += rng.normal(0, 0.15, w.shape) + dz.gyro_bias[0 if o > 0 else 1]
    acc = np.clip(acc, -16, 16)
    w = np.clip(w, -2000, 2000)
    return acc, w, RCd


def quat_from_R(Rm):
    from . import node
    return node.q_from_matrix(Rm)
