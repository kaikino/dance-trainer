"""Python port of the node's sample pipeline, for simulation.

    calibrated IMU sample → Madgwick (madgwick.c) → foot frame (fusion.c)
                          → strike detector (stepdet.c) → int8 window (stepdet.c cut_window)

The simulator (ml/realsim.py) feeds continuous synthetic IMU streams through this
so a rule is judged on the windows the firmware would actually cut, not on
hand-made ones. Two strike detectors are kept: OLD_DETECTOR is the firmware as
it was before the rule rework (|a| peak anchor, 40/20 window); NEW_DETECTOR
(detect_swing) is the current stepdet.c. Keep SwingDetector's defaults and
windows.WIN_PRE/WIN_POST in step with stepdet.h; tests/test_stepdet_parity.py
compiles stepdet's detector for the host and compares.
"""
from dataclasses import dataclass
import math

import numpy as np

from . import windows as W


# ---- Madgwick (madgwick.c, IMU-only update) ----------------------------------

def madgwick_update(q, gx, gy, gz, ax, ay, az, dt, beta=0.1):
    q0, q1, q2, q3 = q
    qd1 = 0.5 * (-q1 * gx - q2 * gy - q3 * gz)
    qd2 = 0.5 * (q0 * gx + q2 * gz - q3 * gy)
    qd3 = 0.5 * (q0 * gy - q1 * gz + q3 * gx)
    qd4 = 0.5 * (q0 * gz + q1 * gy - q2 * gx)
    if not (ax == 0.0 and ay == 0.0 and az == 0.0):
        r = 1.0 / math.sqrt(ax * ax + ay * ay + az * az)
        ax *= r; ay *= r; az *= r
        _2q0, _2q1, _2q2, _2q3 = 2 * q0, 2 * q1, 2 * q2, 2 * q3
        _4q0, _4q1, _4q2 = 4 * q0, 4 * q1, 4 * q2
        _8q1, _8q2 = 8 * q1, 8 * q2
        q0q0, q1q1, q2q2, q3q3 = q0 * q0, q1 * q1, q2 * q2, q3 * q3
        s0 = _4q0 * q2q2 + _2q2 * ax + _4q0 * q1q1 - _2q1 * ay
        s1 = _4q1 * q3q3 - _2q3 * ax + 4 * q0q0 * q1 - _2q0 * ay - _4q1 + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * az
        s2 = 4 * q0q0 * q2 + _2q0 * ax + _4q2 * q3q3 - _2q3 * ay - _4q2 + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * az
        s3 = 4 * q1q1 * q3 - _2q1 * ax + 4 * q2q2 * q3 - _2q2 * ay
        n = math.sqrt(s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3)
        if n > 0:
            qd1 -= beta * s0 / n; qd2 -= beta * s1 / n; qd3 -= beta * s2 / n; qd4 -= beta * s3 / n
    q0 += qd1 * dt; q1 += qd2 * dt; q2 += qd3 * dt; q3 += qd4 * dt
    r = 1.0 / math.sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3)
    return (q0 * r, q1 * r, q2 * r, q3 * r)


def q_rotate(q, v):
    w, x, y, z = q
    return (
        (1 - 2 * (y * y + z * z)) * v[0] + 2 * (x * y - w * z) * v[1] + 2 * (x * z + w * y) * v[2],
        2 * (x * y + w * z) * v[0] + (1 - 2 * (x * x + z * z)) * v[1] + 2 * (y * z - w * x) * v[2],
        2 * (x * z - w * y) * v[0] + 2 * (y * z + w * x) * v[1] + (1 - 2 * (x * x + y * y)) * v[2],
    )


def q_mul(a, b):
    return (
        a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
        a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
        a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
        a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
    )


def q_from_rotvec(r):
    a = math.sqrt(r[0] ** 2 + r[1] ** 2 + r[2] ** 2)
    if a < 1e-12:
        return (1.0, 0.0, 0.0, 0.0)
    s = math.sin(a / 2) / a
    return (math.cos(a / 2), r[0] * s, r[1] * s, r[2] * s)


def q_from_matrix(m: np.ndarray):
    """Rotation matrix (columns = body axes in world) → quaternion w,x,y,z."""
    tr = m[0, 0] + m[1, 1] + m[2, 2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        q = (0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s)
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = ((m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s)
    elif m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = ((m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s)
    else:
        s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = ((m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s)
    n = math.sqrt(sum(c * c for c in q))
    return tuple(c / n for c in q)


# ---- fusion_task (fusion.c) ------------------------------------------------------

class BiasTracker:
    """bias_track() in fusion.c: fold the mean leftover rate of each 1 s still run into the bias."""
    STILL_US, MAX_DPS, JITTER_DPS, ACC_G, GAIN = 1_000_000, 30.0, 5.0, 0.05, 0.5

    def __init__(self):
        self.bias = np.zeros(3)
        self.n = 0

    def update(self, a, g, t_us: int) -> None:
        gm = float(np.linalg.norm(g))
        still = (self.n > 0 and gm < self.MAX_DPS
                 and bool(np.all(np.abs(g - self.g_sum / self.n) < self.JITTER_DPS))
                 and bool(np.all(np.abs(a - self.a_sum / self.n) < self.ACC_G)))
        if not still:
            self.n = 0
            if gm >= self.MAX_DPS:
                return
            self.a_sum, self.g_sum, self.start = np.zeros(3), np.zeros(3), t_us
        self.a_sum = self.a_sum + a
        self.g_sum = self.g_sum + g
        self.n += 1
        if t_us - self.start >= self.STILL_US:
            self.bias = self.bias + self.GAIN * self.g_sum / self.n
            self.n = 0


def fuse(t_us: np.ndarray, acc: np.ndarray, gyr: np.ndarray, right: bool, q0, q_err=None,
         track_bias: bool = True) -> dict:
    """acc (g), gyr (dps): calibrated sensor frame, residual gyro bias included.
    q_err: optional (n, 4) extra world-frame orientation error applied to the
    filter output before it is used (models orientation error the filter itself
    does not produce). Returns dict of arrays: acc, gyr (sensor, NOT mirrored),
    foot (n,3 g, foot frame, y mirrored on the right node)."""
    n = len(t_us)
    foot = np.empty((n, 3))
    gyr_out = np.empty((n, 3))
    q = tuple(q0)
    d2r = math.pi / 180
    last = 0
    bt = BiasTracker() if track_bias else None
    for i in range(n):
        dt = (t_us[i] - last) * 1e-6 if last else 1.0 / 100
        last = t_us[i]
        a = acc[i]
        g = gyr[i] - bt.bias if bt else gyr[i]
        if bt:
            bt.update(a, g, int(t_us[i]))
        gyr_out[i] = g
        q = madgwick_update(q, g[0] * d2r, g[1] * d2r, g[2] * d2r, a[0], a[1], a[2], dt)
        qu = q_mul(tuple(q_err[i]), q) if q_err is not None else q
        aw = q_rotate(qu, a)
        awz = aw[2] - 1.0
        xw = q_rotate(qu, (1.0, 0.0, 0.0))
        yaw = math.atan2(xw[1], xw[0])
        c, s = math.cos(yaw), math.sin(yaw)
        ax_f = c * aw[0] + s * aw[1]
        ay_f = -s * aw[0] + c * aw[1]
        if right:
            ay_f = -ay_f
        foot[i] = (ax_f, ay_f, awz)
    return {"t_us": t_us, "acc": acc, "gyr": gyr_out, "foot": foot}


# ---- strike detector (stepdet.c) -----------------------------------------------------

@dataclass(frozen=True)
class Detector:
    win_pre: int
    win_post: int
    peak_g: float = 1.8
    still_g: float = 0.25
    still_samples: int = 6          # STRIKE_STILL_MS at 10 ms per sample
    refract_ms: int = 200
    settle_timeout: int = 60        # samples after the anchor to see stillness


OLD_DETECTOR = Detector(win_pre=40, win_post=20)


def detect(fused: dict, det: Detector) -> list[int]:
    """Strike anchors as the OLD detect_task() emitted them (|a| peak, then still)."""
    acc, foot, t_us = fused["acc"], fused["foot"], fused["t_us"]
    mag = np.sqrt((acc ** 2).sum(1))
    mag_w = np.sqrt((foot ** 2).sum(1))
    n = len(mag)
    out = []
    st = 0  # 0 SEEK, 1 IN_PEAK, 2 WAIT_STILL
    peak_idx = 0; peak_mag = 0.0; still_run = 0; last_strike_us = -(10 ** 12)
    for idx in range(n):
        m = mag[idx]
        if st == 0:
            if m > det.peak_g and t_us[idx] - last_strike_us > det.refract_ms * 1000:
                st = 1; peak_idx = idx; peak_mag = m
        elif st == 1:
            if m > peak_mag:
                peak_mag = m; peak_idx = idx
            if m < det.peak_g:
                st = 2; still_run = 0
        elif st == 2:
            still_run = still_run + 1 if mag_w[idx] < det.still_g else 0
            if still_run >= det.still_samples and idx >= peak_idx + det.win_post:
                out.append(peak_idx)
                last_strike_us = t_us[peak_idx]
                st = 0
            elif idx > peak_idx + det.settle_timeout:
                st = 0
    return out


def cut(fused: dict, peak_idx: int, right: bool, win_pre: int, win_post: int) -> np.ndarray | None:
    """stepdet.c cut_window(): (win_pre+win_post, 9) int8, sensor channels mirrored on the right node."""
    i0 = peak_idx - win_pre
    i1 = peak_idx + win_post
    n = len(fused["t_us"])
    acc = np.zeros((win_pre + win_post, 3)); gyr = np.zeros_like(acc); foot = np.zeros_like(acc)
    lo, hi = max(i0, 0), min(i1, n)
    acc[lo - i0:hi - i0] = fused["acc"][lo:hi]
    gyr[lo - i0:hi - i0] = fused["gyr"][lo:hi]
    foot[lo - i0:hi - i0] = fused["foot"][lo:hi]
    if right:
        acc, gyr = W.mirror_sensor(acc, gyr)
    return W.quantize(np.concatenate([acc, gyr, foot], axis=1).astype(np.float32))


# ---- swing-end detector (firmware swingdet.c) -----------------------------------------

@dataclass(frozen=True)
class SwingDetector:
    """swingdet.c in Python; the constants there are fixed, these defaults equal them.
    Every comparison is on float32 values computed in the same order as the C, so the
    two agree exactly (tests/test_stepdet_parity.py).

    A swing starts when the shank or foot moves: |gyro| > 100 dps, ||a| - 1 g| > 0.4 g,
    or |a_world| > 0.3 g (a slide barely turns the shank). It ends when the foot is
    planted (shank pitched < 35°):
      - after an impact: |a_world| < 0.4 g, |gyro| < 200 dps for 8 samples, with a
        sensor |a| peak > 1.25 g in the 8 samples before, at least 6 samples into the
        swing (the lift-off push is not a landing);
      - without one: |a_world| < 0.25 g, |gyro| < 60 dps for 20 samples (longer than a
        mid-swing coast).
    A swing is a step if it lasted >= 12 samples and the foot moved: the integral of
    min(|a_world|, 1.5 g) over it >= 0.8 m/s (a bump from the other foot, or the shank rolling
    over the planted foot, is far less). Within 30 samples of the last plant only an
    impact may end a step (the shank rolling forward after a landing is not one). The
    strike is the latest impact in the 15 samples before planting, else the last
    deceleration peak. It is emitted win_post samples later (several can be pending)."""
    win_pre: int
    win_post: int
    act_gyro_dps: float = 100.0
    act_acc_g: float = 0.4
    act_world_g: float = 0.3
    still_gyro_dps: float = 60.0
    still_acc_g: float = 0.25
    still_soft: int = 20
    still_gyro_impact_dps: float = 200.0
    still_acc_impact_g: float = 0.4
    still_samples: int = 8
    impact_g: float = 1.25
    impact_near: int = 8
    impact_after: int = 6
    anchor_back: int = 15
    min_swing: int = 12
    min_motion: float = 8.48        # ∫min(|a_world|, 1.5 g) in g·samples (0.8 m/s at 104 Hz)
    motion_cap_g: float = 1.5
    guard: int = 30
    max_swing: int = 160
    max_pitch_sin: float = 0.57
    refract_ms: int = 200


def _f2(v) -> np.float32:
    return np.float32(v) * np.float32(v)


def _sq3(x: np.ndarray) -> np.ndarray:
    x = x.astype(np.float32)
    return (x[:, 0] * x[:, 0] + x[:, 1] * x[:, 1]) + x[:, 2] * x[:, 2]


def _latest_peak(v, lo, hi, thr):
    for j in range(hi, lo - 1, -1):
        if j < 1:
            break
        if v[j] > thr and v[j] >= v[j - 1] and v[j] >= v[j + 1]:
            return j
    return -1


def detect_swing(fused: dict, det: SwingDetector) -> list[int]:
    """Strike anchors as swingdet.c emits them: one per step, at the landing impact (or
    where a soft landing decelerated), win_post samples after it."""
    acc = fused["acc"].astype(np.float32)
    t_us = fused["t_us"]
    mag2 = _sq3(acc); gm2 = _sq3(fused["gyr"]); magw2 = _sq3(fused["foot"])
    magw = np.minimum(np.sqrt(magw2), np.float32(det.motion_cap_g))   # float32 sqrt = sqrtf; capped:
    # a one-sample knock (strap, other foot) is not foot motion
    ax2 = acc[:, 0] * acc[:, 0]
    ACT_G2 = _f2(det.act_gyro_dps); HI2 = _f2(1 + det.act_acc_g); LO2 = _f2(1 - det.act_acc_g)
    ACT_W2 = _f2(det.act_world_g)
    ST_G2 = _f2(det.still_gyro_dps); ST_A2 = _f2(det.still_acc_g)
    LO_G2 = _f2(det.still_gyro_impact_dps); LO_A2 = _f2(det.still_acc_impact_g)
    IMP2 = _f2(det.impact_g); PITCH2 = _f2(det.max_pitch_sin); MOT = np.float32(det.min_motion)
    out = []
    pend = []                                   # anchors waiting for their post-strike samples
    moving = False
    start = 0; still_run = 0; loose_run = 0; last_us = None; last_end = -(1 << 30)
    mot = np.float32(0); still_sum = np.float32(0); loose_sum = np.float32(0)
    for idx in range(len(mag2)):
        if pend and idx >= pend[0] + det.win_post:    # at most one per sample (anchors are > 20 apart)
            out.append(pend.pop(0))
        active = gm2[idx] > ACT_G2 or mag2[idx] > HI2 or mag2[idx] < LO2 or magw2[idx] > ACT_W2
        upright = ax2[idx] < PITCH2 * mag2[idx]
        quiet = upright and magw2[idx] < ST_A2 and gm2[idx] < ST_G2
        loose = upright and magw2[idx] < LO_A2 and gm2[idx] < LO_G2
        if not moving:
            if active:
                moving = True; start = idx; still_run = 0; loose_run = 0
                mot = magw[idx]; still_sum = np.float32(0); loose_sum = np.float32(0)
            continue
        mot = mot + magw[idx]
        if quiet:
            still_run += 1; still_sum = still_sum + magw[idx]
        else:
            still_run = 0; still_sum = np.float32(0)
        if loose:
            loose_run += 1; loose_sum = loose_sum + magw[idx]
        else:
            loose_run = 0; loose_sum = np.float32(0)
        settled = False; impact = False
        end = 0; m = np.float32(0)
        if loose_run == det.still_samples:
            end = idx - loose_run + 1
            lo = max(end - det.impact_near, start + det.impact_after)
            if _latest_peak(mag2, lo, end, IMP2) >= 0:
                settled = True; impact = True; m = mot - loose_sum
        if not settled and still_run >= det.still_soft:
            end = idx - still_run + 1
            settled = True; m = mot - still_sum
        if settled:
            moving = False
            if end - start < det.min_swing or m < MOT:
                continue
            if not impact and start - last_end < det.guard:
                continue
            lo = max(end - det.anchor_back, start)
            a = _latest_peak(mag2, lo, end, IMP2)
            if a < 0:   # soft landing: the last deceleration peak
                a = _latest_peak(magw2, lo, end, np.float32(0))
            if a < 0:
                a = max(end - 3, start)
            if last_us is not None and t_us[a] - last_us <= det.refract_ms * 1000:
                continue
            last_us = t_us[a]; last_end = end
            if len(pend) == 4:     # cannot happen (refractory vs win_post); keep the newest
                pend.pop(0)
            pend.append(a)         # a + win_post > idx always: anchor_back + still_soft < win_post
        elif idx - start > det.max_swing:
            moving = False
    return out


# Must match stepdet.h.
NEW_DETECTOR = SwingDetector(win_pre=W.WIN_PRE, win_post=W.WIN_POST)
