"""Adversarial physical simulator of one ankle node during one dance step.

Unlike synth.py (hand-drawn accel pulses), this builds the motion from body
geometry and pushes it through a sensor model:

  1. Ankle path: minimum-jerk swing between planned foot positions, a lift
     profile, touchdown before the planned end (so the foot still moves when it
     lands), then the floor stops it within tau (hard floor short, carpet long).
     Kicks swing the ankle on an arc about the hip and come back down.
  2. Pelvis follows weight transfer; the hip joint and the ankle give the knee
     by two-link inverse kinematics, so the shank (where the strap sits) pitches
     and rolls the way a leg does, also during "stance".
  3. Sensor on the shank r_s above the ankle: specific force and angular rate
     from the 1040 Hz trajectory, plus heel-strike shock ringing.
  4. Calibration error (heading up to ±20°, tilt), LSM6DS3 errors (bias,
     scale, cross-axis, noise, ±16 g / ±2000 dps saturation, LSB quantization),
     point sampling at an inexact 104 Hz ODR (aliasing included).
  5. The firmware pipeline (dt.node): Madgwick, foot frame, strike detector,
     int8 window. Extra world-frame orientation error (static + during swing) is
     injected after the filter.

A trial is: stand still, a previous step of the same foot, a stance gap set by
the tempo (can be very short), the target step, stance. The right foot is the
mirror image (exact: accel y and gyro x, z flip) and runs the right-node path.
"""
from dataclasses import dataclass, field, replace
import math

import numpy as np

from . import node
from .protocol import StepClass

FS = 1040.0          # internal simulation rate (10 × ODR)
ODR = 104.0          # LSM6DS3 data rate the firmware samples at
G = 9.80665
D2R = math.pi / 180

CLASSES = [StepClass.IN_PLACE, StepClass.FORWARD, StepClass.BACK, StepClass.SIDE_OUT,
           StepClass.CROSS, StepClass.KICK, StepClass.SIDE_IN,
           StepClass.FORWARD_OUT, StepClass.FORWARD_IN, StepClass.BACK_OUT, StepClass.BACK_IN,
           StepClass.CROSS_BEHIND]


@dataclass(frozen=True)
class Realism:
    """Magnitudes of every adversarial knob. In 'uniform' mode each trial draws
    U(-m, m) (or U(lo, hi) for ranges); in 'edge' mode the named knobs sit at
    ±m exactly (random sign/axis). Defaults are the realistic ranges."""
    tempo_bpm: tuple = (70.0, 140.0)
    height_m: tuple = (1.50, 1.95)
    step_scale: tuple = (0.80, 1.15)       # normal steps, × the height-based step length
    lazy_p: float = 0.30                   # share of lazy steps
    lazy_scale: tuple = (0.55, 0.80)       # lazy step length / lift factor
    acc_bias_g: float = 0.05
    acc_scale: float = 0.03
    acc_cross: float = 0.01
    acc_noise_g: float = 0.008
    gyro_bias_dps: float = 3.0             # residual after the still-pose calibration
    gyro_scale: float = 0.03
    gyro_noise_dps: float = 0.7
    tilt_static_deg: float = 5.0           # extra world-frame orientation error, constant
    tilt_dyn_deg: float = 5.0              # extra error growing with rotation rate during the swing
    cal_tilt_deg: float = 5.0              # calibrated z vs shank axis
    heading_deg: float = 20.0              # calibrated x vs toe direction (slide gesture error)
    toe_out_deg: tuple = (0.0, 0.0)        # toe-out the slide calibration did NOT absorb (it is part of
                                           # heading_deg when the slide is body-forward); plus ±10° turn per swing
    shock_hard_g: tuple = (3.0, 8.0)
    shock_carpet_g: tuple = (1.5, 3.5)
    shock_soft_g: tuple = (1.15, 2.0)      # taps and placed lazy steps
    p_carpet: float = 0.35
    p_soft: float = 0.15
    odr_err: float = 0.02
    gap_min_s: float = 0.06                # shortest stance between the previous and the target step
    land_speed: float = 1.0                # × touchdown velocity (horizontal + vertical)
    kick_hold_p: float = 0.25              # kicks held in the air before the return
    kick_angle_deg: tuple = (30.0, 80.0)
    crosstalk_g: float = 0.6               # other foot landing, felt through the body
    edge: frozenset = field(default_factory=frozenset)   # knobs forced to ±max


def _u(rng, R: Realism, name: str):
    """Signed draw for a symmetric knob."""
    m = getattr(R, name)
    if name in R.edge:
        return m * rng.choice([-1.0, 1.0])
    return rng.uniform(-m, m)


def _mag(rng, R: Realism, name: str):
    m = getattr(R, name)
    return m if name in R.edge else rng.uniform(0, m)


def _rng(rng, lohi):
    return rng.uniform(*lohi)


def minjerk(s):
    s = np.clip(s, 0.0, 1.0)
    return s ** 3 * (10 - 15 * s + 6 * s * s)


def bump(u):
    """0 → 1 → 0 over u in [0, 1], zero velocity and acceleration at both ends."""
    u = np.clip(u, 0.0, 1.0)
    return 64.0 * u ** 3 * (1 - u) ** 3


def _rotz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])


def _rotvec(v):
    a = np.linalg.norm(v)
    if a < 1e-12:
        return np.eye(3)
    k = v / a
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + math.sin(a) * K + (1 - math.cos(a)) * K @ K


def _smooth(x, n):
    if n <= 1:
        return x
    k = np.ones(n) / n
    pad = np.pad(x, ((n // 2, n - 1 - n // 2),) + ((0, 0),) * (x.ndim - 1), mode="edge")
    if x.ndim == 1:
        return np.convolve(pad, k, mode="valid")
    return np.stack([np.convolve(pad[:, j], k, mode="valid") for j in range(x.shape[1])], axis=1)


@dataclass
class Body:
    H: float
    Lt: float
    Ls: float
    ha: float
    hip_half: float
    s0: float           # stance width, ankle to ankle
    hip_h: float        # hip joint height when standing (knees slightly soft)


def _body(rng, R):
    H = _rng(rng, R.height_m)
    ha = 0.039 * H
    return Body(H=H, Lt=0.245 * H, Ls=0.246 * H, ha=ha, hip_half=0.055 * H, s0=rng.uniform(0.05, 0.12) * H,
                hip_h=ha + 0.491 * H * rng.uniform(0.975, 0.995))


# ---- planned foot motion ---------------------------------------------------------

@dataclass
class Swing:
    t0: float               # lift-off
    Ts: float               # lift-off → touchdown
    p0: np.ndarray          # ankle start (x, y)
    p1: np.ndarray          # planned end (x, y); touchdown happens before it is reached
    lift: float             # m
    Th_ratio: float         # horizontal min-jerk length / Ts (≥1: still moving at touchdown)
    gamma: float            # lift-profile skew, -0.4..0.4
    kappa: float            # vertical touchdown speed, m/s
    tau: float              # floor stop time
    shock_g: float
    w_sw: float             # weight share on this foot during the swing
    w_end: float            # after landing
    yaw_turn: float         # rad, foot turn during the swing
    kick: dict | None = None


def _plan(cls: StepClass, rng, R: Realism, b: Body, beat: float):
    """Start/end ankle positions (x fwd, y outward for this foot, other foot at y=0),
    lift and the swing timing for one step of class cls."""
    lazy = rng.random() < R.lazy_p
    f = _rng(rng, R.lazy_scale) if lazy else _rng(rng, R.step_scale)
    H = b.H
    p0 = np.array([0.0, b.s0])
    nx = lambda: rng.normal(0, 0.012 * H)
    lift = rng.uniform(0.02, 0.06) * H * f
    w_end = rng.uniform(0.5, 1.0)
    if cls == StepClass.FORWARD:
        p1 = p0 + [rng.uniform(0.14, 0.24) * H * f, nx()]
    elif cls == StepClass.BACK:
        p1 = p0 + [-rng.uniform(0.12, 0.21) * H * f, nx()]
        lift *= 0.7
    elif cls == StepClass.SIDE_OUT:
        p1 = p0 + [nx(), rng.uniform(0.12, 0.22) * H * f]
    elif cls == StepClass.SIDE_IN:
        p0 = np.array([nx(), b.s0 + rng.uniform(0.10, 0.22) * H * f])
        p1 = np.array([nx(), rng.uniform(0.04, 0.10) * H])
    elif cls in (StepClass.CROSS, StepClass.CROSS_BEHIND):
        # past the other foot (y < 0), in front of it or behind it
        p0 = np.array([0.0, b.s0 + rng.uniform(0.0, 0.22) * H])
        sx = 1 if cls == StepClass.CROSS else -1
        p1 = np.array([sx * rng.uniform(0.05, 0.12) * H, -rng.uniform(0.02, 0.10) * H])
        if cls == StepClass.CROSS_BEHIND:
            lift *= 0.7
    elif cls in (StepClass.FORWARD_OUT, StepClass.BACK_OUT):
        # diagonal, 35-55° off the toe line
        sx = 1 if cls == StepClass.FORWARD_OUT else -1
        dy = rng.uniform(0.08, 0.15) * H * f
        p1 = p0 + [sx * dy * rng.uniform(0.7, 1.4), dy]
        if sx < 0:
            lift *= 0.7
    elif cls in (StepClass.FORWARD_IN, StepClass.BACK_IN):
        # from wide, diagonally in to close beside the other foot
        sx = 1 if cls == StepClass.FORWARD_IN else -1
        p0 = np.array([nx(), b.s0 + rng.uniform(0.08, 0.15) * H * f])
        p1 = np.array([0.0, rng.uniform(0.04, 0.10) * H])
        p1[0] = p0[0] + sx * (p0[1] - p1[1]) * rng.uniform(0.7, 1.4)
        if sx < 0:
            lift *= 0.7
    elif cls == StepClass.IN_PLACE:
        p1 = p0 + np.clip(rng.normal(0, 0.012 * H, 2), -0.025, 0.025)
        lift = rng.uniform(0.02, 0.12) * H * (f if lazy else 1.0)
        w_end = rng.uniform(0.3, 1.0)
    elif cls == StepClass.KICK:
        p1 = p0 + [rng.uniform(-0.03, 0.08) * H, nx()]
        lift = 0.0
    else:
        raise ValueError(cls)

    soft = rng.random()
    if soft < R.p_soft or (lazy and soft < 2 * R.p_soft):
        shock = _rng(rng, R.shock_soft_g); tau = rng.uniform(0.03, 0.06)
        if cls != StepClass.KICK:
            w_end = rng.uniform(0.0, 1.0)      # a tap may not take weight
    elif soft < R.p_soft + R.p_carpet:
        shock = _rng(rng, R.shock_carpet_g); tau = rng.uniform(0.02, 0.045)
    else:
        shock = _rng(rng, R.shock_hard_g); tau = rng.uniform(0.006, 0.015)

    Ts = float(np.clip(rng.uniform(0.40, 0.85) * beat, 0.18, 0.75))
    # Feet do not exceed ~2.5 g peak swing acceleration: long or high steps take longer.
    dist = float(np.linalg.norm(p1 - p0))
    Ts = max(Ts, math.sqrt(5.77 * dist / (2.5 * G)), math.sqrt(20 * lift / (2.5 * G)))
    kick = None
    if cls == StepClass.KICK:
        phi = _rng(rng, R.kick_angle_deg) * D2R
        # higher kicks take longer; peak shank rate 250-500 dps, ankle accel 4-8 g
        t_min = 0.2 + 0.15 * (phi / D2R - 30) / 50
        Tk = float(np.clip(rng.uniform(0.3, 0.5) * beat, t_min, 0.45))
        Tr = float(np.clip(rng.uniform(0.3, 0.5) * beat, t_min, 0.45))
        hold = rng.uniform(0.1, 0.3) if rng.random() < R.kick_hold_p else rng.uniform(0.0, 0.05)
        kick = dict(phi=phi, Tk=Tk, Tr=Tr, hold=hold, over=rng.uniform(0.03, 0.15), bend=rng.uniform(0.0, 0.5),
                    lean=rng.uniform(0.0, 0.05))
        Ts = Tk + hold + Tr
    return Swing(t0=0.0, Ts=Ts, p0=p0, p1=p1, lift=lift, Th_ratio=1.0 + rng.uniform(0.0, 0.15) * R.land_speed,
                 gamma=rng.uniform(-0.4, 0.4), kappa=rng.uniform(0.05, 0.45) * R.land_speed, tau=tau,
                 shock_g=shock, w_sw=rng.uniform(0.0, 0.3), w_end=w_end,
                 yaw_turn=rng.uniform(-10, 10) * D2R, kick=kick)


# ---- trajectories -------------------------------------------------------------------

def _swing_path(t, sw: Swing, b: Body, hip_xy_fn):
    """Planned ankle path (n,3) during [t0, t0+Ts] (position before t0 = start),
    and the touchdown time. Kicks use the hip for the arc."""
    n = len(t)
    p = np.zeros((n, 3))
    p[:, :2] = sw.p0
    p[:, 2] = b.ha
    u = (t - sw.t0) / sw.Ts
    if sw.kick is None:
        Th = sw.Ts * sw.Th_ratio
        s = minjerk((t - sw.t0) / Th)
        p[:, :2] = sw.p0 + np.outer(s, sw.p1 - sw.p0)
        uc = np.clip(u, 0, 1)
        uu = uc + sw.gamma * uc * (1 - uc)          # smooth warp: lift peaks early (gamma>0) or late
        # bump lift, plus a term that lands with vertical speed kappa (m/s)
        z = sw.lift * bump(uu) + sw.kappa * sw.Ts * uc ** 3 * (1 - uc)
        p[:, 2] = b.ha + z
        return p, sw.t0 + sw.Ts
    k = sw.kick
    L0 = b.hip_h - b.ha
    hip = hip_xy_fn(t)
    tk = (t - sw.t0) / k["Tk"]
    tr = (t - sw.t0 - k["Tk"] - k["hold"]) / k["Tr"]
    target = -k["over"] * k["phi"]
    phi = np.where(tr <= 0, k["phi"] * minjerk(tk), k["phi"] + (target - k["phi"]) * minjerk(tr / 1.0))
    # knee bend (flick) early in the kick: shorter hip-ankle distance, straight at the top
    r = L0 * (1 - 0.12 * k["bend"] * bump(tk))
    hz = b.hip_h
    # ankle on the arc; horizontal offset from where the hip was over the ankle at rest
    ax0 = sw.p0[0]
    hx = np.where(t < sw.t0, 0.0, hip[:, 0] - np.interp(sw.t0, t, hip[:, 0]))
    p[:, 0] = ax0 + hx + r * np.sin(phi)
    p[:, 1] = sw.p0[1]
    p[:, 2] = hz - r * np.cos(phi)
    # return lands where phi crosses 0 again; the landing spot drifts toward p1
    land = minjerk(np.clip(tr, 0, 1))
    p[:, :2] += np.outer(land, sw.p1 - sw.p0)
    after = (tr > 0) & (phi <= 0)
    t_land = t[np.argmax(after)] if after.any() else sw.t0 + sw.Ts
    return p, t_land


def _land(t, p_plan, t_c, tau, t_from):
    """Actual ankle path: follows the plan after t_from until touchdown t_c, then
    the floor removes the remaining velocity over tau. Returns position, landing velocity."""
    dt = 1 / FS
    v = np.gradient(p_plan, dt, axis=0)
    ic = int(round(t_c * FS))
    ic = min(max(ic, 1), len(t) - 1)
    vtd = v[ic].copy()
    v[:int(round(t_from * FS))] = 0
    dec = (t - t_c) / tau
    fac = np.where(dec < 1, 0.5 * (1 + np.cos(np.pi * np.clip(dec, 0, 1))), 0.0)
    v[ic:] = np.outer(fac[ic:], vtd)
    p = p_plan[0] + np.cumsum(v, axis=0) * dt
    return p, vtd


def _weight(t, keys):
    """Piecewise min-jerk weight share from keyframes [(t, w), ...]."""
    w = np.full(len(t), keys[0][1])
    ta, wa = keys[0]
    for tb, wb in keys[1:]:
        if tb <= ta and wb == wa:
            continue
        tb = max(tb, ta + 0.01)
        s = minjerk((t - ta) / (tb - ta))
        m = t >= ta
        w[m] = wa + (wb - wa) * s[m]
        ta, wa = tb, wb
    return w


@dataclass
class Trial:
    cls: StepClass
    foot: str
    fused: dict
    t_contact: float           # s, target touchdown (kick: return landing)
    t_lift: float              # s, target lift-off
    t_prev_contact: float
    truth: dict


def simulate(cls: StepClass, rng: np.random.Generator, R: Realism = Realism(), foot: str = "L", debug: bool = False) -> Trial:
    b = _body(rng, R)
    bpm = _rng(rng, R.tempo_bpm)
    beat = 60.0 / bpm
    target = _plan(cls, rng, R, b, beat)

    # Previous step of the same foot: ends where the target starts.
    prev_cls = rng.choice([StepClass.FORWARD, StepClass.BACK, StepClass.SIDE_OUT, StepClass.IN_PLACE, StepClass.SIDE_IN])
    prev = _plan(StepClass(prev_cls), rng, R, b, beat)
    dprev = prev.p1 - prev.p0
    prev.p1 = target.p0.copy()
    prev.p0 = target.p0 - dprev
    if prev_cls == StepClass.SIDE_IN:
        prev.p0 = target.p0 + [0, rng.uniform(0.05, 0.2) * b.H]
    prev.kick = None

    lead = 1.2
    prev.t0 = lead
    t_prev_c = prev.t0 + prev.Ts
    k = 1 if rng.random() < 0.3 else 2
    gap = R.gap_min_s if "gap_min_s" in R.edge else max(R.gap_min_s, k * beat - target.Ts - prev.tau)
    target.t0 = t_prev_c + prev.tau + gap
    T = target.t0 + target.Ts + 1.0
    t = np.arange(int(T * FS)) / FS
    n = len(t)

    # Pelvis: weight share w on this foot. Off this foot before each swing, back after.
    # A short stance only half-transfers the weight; shifts take half the stance each.
    span = gap + prev.tau
    w_mid = prev.w_sw + (prev.w_end - prev.w_sw) * min(1.0, span / 0.4)
    sh = min(0.25, span / 2)
    w = _weight(t, [(0, rng.uniform(0.3, 0.6)), (prev.t0 - 0.25, 0.4), (prev.t0, prev.w_sw), (t_prev_c, prev.w_sw),
                    (t_prev_c + sh, w_mid), (target.t0 - sh, w_mid),
                    (target.t0, target.w_sw), (target.t0 + target.Ts, target.w_sw),
                    (target.t0 + target.Ts + 0.3, target.w_end)])
    other = np.array([rng.normal(0, 0.02 * b.H), 0.0])

    # Ankle: previous swing, then target swing.
    pp, _ = _swing_path(t, prev, b, None)
    pa, vprev = _land(t, pp, t_prev_c, prev.tau, prev.t0)
    pa -= pa[-1] - np.append(target.p0, b.ha)      # end exactly at the target start

    lean = np.zeros(n)
    hip_fn = None
    if target.kick:   # pelvis leans back a little during a kick
        lean = target.kick["lean"] * bump((t - target.t0) / target.Ts)
        hip_fn = lambda tt: (other + np.interp(tt, t, w)[:, None] * (target.p0 - other)) - np.outer(np.interp(tt, t, lean), [1, 0])
    pt, t_c = _swing_path(t, target, b, hip_fn)
    pt_act, vtd = _land(t, pt, t_c, target.tau, target.t0)
    after = t >= target.t0
    ankle = np.where(after[:, None], pt_act, pa)

    # Foot yaw: toe-out + turn during the target swing.
    toe_out = _rng(rng, R.toe_out_deg) * D2R
    psi = toe_out + target.yaw_turn * minjerk((t - target.t0) / target.Ts)

    # Pelvis, hip joint, IK.
    pel = other + w[:, None] * ((target.p0 if target.kick else ankle[:, :2]) - other)
    pel[:, 0] -= lean
    hip = np.zeros((n, 3))
    hip[:, :2] = pel + np.array([0, b.hip_half])   # this leg's hip joint, outward of the pelvis centre
    hip[:, 2] = b.hip_h
    # Shank direction: the ankle→hip line, tilted forward by the knee bend. For two
    # equal segments the shank leaves that line at half the knee flexion. An
    # explicit smooth bend profile (not inverse kinematics, which spins the shank
    # near full extension): soft stance knee, more bend in each swing to lift the foot.
    lat = np.stack([-np.sin(psi), np.cos(psi), np.zeros(n)], axis=1)   # foot's left axis
    uh = (hip - ankle) / np.linalg.norm(hip - ankle, axis=1)[:, None]
    nvec = np.cross(lat, uh)
    nvec /= np.linalg.norm(nvec, axis=1)[:, None]
    beta = np.full(n, rng.uniform(3, 8) * D2R)
    for sw, tc in ((prev, t_prev_c), (target, t_c)):
        if sw.kick:
            beta += sw.kick["bend"] * 40 * D2R * bump((t - sw.t0) / sw.kick["Tk"])
        else:
            beta += min(45.0, 12 + 120 * sw.lift) * D2R * bump((t - sw.t0) / (tc - sw.t0))
    zs = np.cos(beta)[:, None] * uh + np.sin(beta)[:, None] * nvec       # ankle → knee, unit
    xs = np.cross(lat, zs)
    xs /= np.linalg.norm(xs, axis=1)[:, None]
    ys = np.cross(zs, xs)
    Rm = np.stack([xs, ys, zs], axis=2)                # columns = shank axes in world

    r_s = rng.uniform(0.04, 0.12)
    sensor = ankle + r_s * zs + 0.04 * xs
    dt = 1 / FS
    vel = np.gradient(sensor, dt, axis=0)
    acc_w = np.gradient(vel, dt, axis=0)
    acc_w[:, 2] += G
    f_s = np.einsum("nji,nj->ni", Rm, acc_w) / G         # R^T a
    Rd = np.gradient(Rm, dt, axis=0)
    Om = np.einsum("nki,nkj->nij", Rm, Rd)               # R^T dR
    omega = np.stack([Om[:, 2, 1] - Om[:, 1, 2], Om[:, 0, 2] - Om[:, 2, 0], Om[:, 1, 0] - Om[:, 0, 1]], axis=1) * 0.5 / D2R

    # Heel-strike shock: ringing along the shank (plus some sideways), on top of the stop pulse.
    def shock(tc, peak, tau):
        if peak <= 1.0:
            return
        ic = int(tc * FS)
        fr = rng.uniform(20, 50); td = rng.uniform(0.008, 0.025)
        dirv = np.array([rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 1.0])
        dirv /= np.linalg.norm(dirv)
        tt = t[ic:] - t[ic]
        ring = np.exp(-tt / td) * np.sin(2 * np.pi * fr * tt + rng.uniform(0, 0.5))
        base = np.abs(f_s[ic:ic + int(0.05 * FS)]).max() if ic < n else 1.0
        amp = max(peak - base, 0.0)
        f_s[ic:] += np.outer(ring * amp, dirv)
        omega[ic:] += np.outer(ring * amp * rng.uniform(0, 25), [rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.3, 0.3)])

    shock(t_prev_c, prev.shock_g, prev.tau)
    shock(t_c, target.shock_g, target.tau)
    # The other foot lands mid-gap: felt through the body.
    ct = _mag(rng, R, "crosstalk_g")
    if ct > 0:
        tx = t_prev_c + prev.tau + rng.uniform(0.3, 0.7) * gap
        ic = int(tx * FS)
        tt = t[ic:] - t[ic]
        f_s[ic:, 2] += ct * np.exp(-tt / 0.02) * np.sin(2 * np.pi * 15 * tt)

    # Calibration error: calibrated frame C vs shank frame S.
    head = _u(rng, R, "heading_deg") * D2R
    ct_ax = rng.normal(size=2); ct_ax /= np.linalg.norm(ct_ax)
    R_SC = _rotz(head) @ _rotvec(np.append(ct_ax * _mag(rng, R, "cal_tilt_deg") * D2R, 0))
    f_c = f_s @ R_SC          # R_SC^T f for each row
    w_c = omega @ R_SC

    # Sample at the (inexact) ODR, IMU errors.
    odr = ODR * (1 + _u(rng, R, "odr_err"))
    ns = int((T - 0.05) * odr)
    ts = np.arange(ns) / odr
    idx = np.minimum(np.round(ts * FS).astype(int), n - 1)
    A = f_c[idx].copy(); Gy = w_c[idx].copy()
    Ma = np.eye(3) + np.diag([_u(rng, R, "acc_scale") for _ in range(3)]) + (rng.uniform(-1, 1, (3, 3)) * R.acc_cross) * (1 - np.eye(3))
    Mg = np.eye(3) + np.diag([_u(rng, R, "gyro_scale") for _ in range(3)])
    ba = np.array([_u(rng, R, "acc_bias_g") for _ in range(3)])
    bg = np.array([_u(rng, R, "gyro_bias_dps") for _ in range(3)])
    A = A @ Ma.T + ba + rng.normal(0, R.acc_noise_g, A.shape)
    Gy = Gy @ Mg.T + bg + rng.normal(0, R.gyro_noise_dps, Gy.shape)
    A = np.clip(A, -16, 16); Gy = np.clip(Gy, -2000, 2000)
    A = np.round(A / 0.000488) * 0.000488
    Gy = np.round(Gy / 0.07) * 0.07
    if foot == "R":   # mirror image of the left foot's motion, seen by a right-handed sensor
        A[:, 1] *= -1
        Gy[:, 0] *= -1; Gy[:, 2] *= -1

    # Extra orientation error after the filter.
    e_s = np.append(rng.normal(size=2), 0); e_s *= _mag(rng, R, "tilt_static_deg") * D2R / np.linalg.norm(e_s)
    e_d = np.append(rng.normal(size=2), 0); e_d *= _mag(rng, R, "tilt_dyn_deg") * D2R / np.linalg.norm(e_d)
    env = _smooth(np.clip(np.linalg.norm(omega[idx], axis=1) / 300.0, 0, 1), 8)
    q_err = np.array([node.q_from_rotvec(e_s + e_d * env[i]) for i in range(ns)])

    # Madgwick starts converged on the true orientation of the calibrated frame.
    Rw = Rm[idx[0]] @ R_SC
    if foot == "R":
        Mm = np.diag([1.0, -1.0, 1.0])
        Rw = Mm @ Rw @ Mm
    q0 = node.q_from_matrix(Rw)
    t_us = (1_000_000 + ts * 1e6).astype(np.int64)
    fused = node.fuse(t_us, A, Gy, foot == "R", q0, q_err)
    fused["t"] = ts

    disp = ankle[-1, :2] - target.p0
    truth = dict(disp_cm=disp * 100, height_m=b.H, bpm=bpm, Ts=target.Ts, lift_cm=target.lift * 100,
                 shock_g=target.shock_g, gap=gap, v_land=float(np.linalg.norm(vtd)), heading_deg=head / D2R,
                 kick_deg=(target.kick["phi"] / D2R if target.kick else 0.0), prev=int(prev_cls),
                 peak_z_cm=float((ankle[after, 2].max() - b.ha) * 100))
    if debug:
        truth["debug"] = dict(t=t, ankle=ankle, hip=hip, zs=zs, f_s=f_s, w=w, beta=beta,
                              pel=pel, other=other, hip_half=b.hip_half, hip_h=b.hip_h, ha=b.ha, H=b.H,
                              acc_bias=ba, R_SC=R_SC)
    return Trial(cls=cls, foot=foot, fused=fused, t_contact=t_c, t_lift=target.t0, t_prev_contact=t_prev_c, truth=truth)
