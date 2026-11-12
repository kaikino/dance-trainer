"""Rule-based step classifier. Must match firmware rules.c exactly (integer
arithmetic throughout, so the two agree bit for bit; tests/test_rules_parity.py).

Pedestrian-dead-reckoning on one int8 window (dt/windows.py), in physical units:

  1. Landing: the latest sensor |a| peak >= 1.25 g near the strike index (the
     detector anchors there; this re-finds it if the anchor drifted).
  2. End ZUPT: the first sample after the landing where the foot is planted
     (|a_world| < 0.4 g, |gyro| < 200 dps for 3 samples).
  3. Start ZUPT: walking back from the last fast shank rotation (>= 100 dps)
     before the landing, the latest sample that is gyro-quiet (< 40 dps for 5
     samples, or 3 with |dz| < 1 cm: a short stance between quick steps) with the
     shank upright (pitch < 35°), AND from which the foot ends at the same height
     (|dz| < 3.5 cm). A pause at peak lift or a kick apex is quiet too, but the
     foot then drops by the lift height, so it is skipped.
  4. Integrate foot-frame accel from start to end with zero velocity at both
     ends (linear velocity de-drift): constant accel bias and leaked gravity
     (tilt error) cancel exactly, whatever the swing length or tempo.
  5. Classify on the horizontal displacement direction (angle sectors) and
     distance in cm; kick from shank pitch (gyro), foot height, and a toe-up
     swing that comes back where it left (a step that swings the shank as far
     travels); cross vs
     side_in from the shank roll right after landing (a crossing foot lands past
     the standing one, so its shank leans inward, roll <= -4°; a close lands
     under its hip).

Displacements are kept as twice the de-drifted double sum, in accel LSB ×
samples², which is an exact integer; thresholds are converted to that unit once
(thresholds()), and rules.c carries the same integers (checked by the tests).
"""
import math

import numpy as np

from .protocol import StepClass
from .windows import SCALES, WIN_LEN, WIN_PRE

# ---- physical constants -----------------------------------------------------------------

ODR_HZ = 104.0                        # LSM6DS3 data rate; one window sample per reading
G = 9.80665
ACC_LSB_G = float(SCALES[6]) / 127    # world and sensor accel share the scale (8 g)
GYR_LSB_DPS = float(SCALES[3]) / 127
assert SCALES[0] == SCALES[6], "rules assume sensor and world accel share a scale"

PHYS = dict(
    impact_g=1.25,          # landing impact (sensor |a| local peak)
    impact_back=30,         # samples before the strike index to look for it
    planted_g=0.4,          # end ZUPT: |a_world| below ...
    planted_dps=200.0,      # ... and |gyro| below, 3 samples in a row
    swing_dps=100.0,        # shank rotation that marks the swing (60 if none reaches it)
    swing_dps_low=60.0,
    quiet_dps=40.0,         # start ZUPT: |gyro| below this for 2*QUIET_HW+1 samples
    upright_pitch_deg=35.0,
    zupt_dz_cm=3.5,         # start ZUPT must be at landing height
    zupt_dz_short_cm=1.0,   # ... tighter when only 3 samples are quiet (a short stance, or a pause mid-swing)
    move_cm=6.0,            # below: in place
    inward_half_deg=55.0,   # inward sector half-width around -y (crosses land in front/behind)
    cross_roll_deg=-4.0,    # shank roll after landing at or below this: cross
    kick_pitch_deg=28.0,    # shank swings forward (toe up) at least this much
    kick_range_deg=55.0,    # or the shank pitch spans this much anywhere in the window
    kick_z_cm=15.0,         # or the foot rises this high while swinging forward kick_pitch2
    kick_pitch2_deg=20.0,
    kick_drop_cm=15.0,      # or the integration had to start in the air (a held kick)
    kick_low_pitch_deg=18.0,  # or a low kick: toe-up at least this much ...
    kick_low_cm=15.0,         # ... and the foot came back down within this of where it left
)
QUIET_HW = 2
FALLBACK_BACK = 60          # samples searched for the quietest point when no ZUPT is found
ROLL_SAMPLES = 8            # samples from the end ZUPT averaged for the roll


def _cm_per_d2() -> float:
    """cm per unit of the doubled de-drifted double sum."""
    return 0.5 * ACC_LSB_G * G / ODR_HZ ** 2 * 100


def thresholds(p: dict | None = None) -> dict:
    """Integer thresholds in window units. rules.c #defines must equal these."""
    p = PHYS if p is None else p
    a = lambda g: g / ACC_LSB_G
    w = lambda dps: dps / GYR_LSB_DPS
    deg_sum = lambda deg: deg / (GYR_LSB_DPS / ODR_HZ)          # gyro LSB·samples
    d2 = lambda cm: cm / _cm_per_d2()
    return dict(
        IMPACT2=int(round(a(p["impact_g"]) ** 2)),
        IMPACT_BACK=int(p["impact_back"]),
        PLANT_A2=int(round(a(p["planted_g"]) ** 2)),
        PLANT_G2=int(round(w(p["planted_dps"]) ** 2)),
        SWING_G2=int(round(w(p["swing_dps"]) ** 2)),
        SWING_LOW_G2=int(round(w(p["swing_dps_low"]) ** 2)),
        QUIET_G2=int(round(w(p["quiet_dps"]) ** 2)),
        UPRIGHT_SIN2_X100=int(round(100 * math.sin(math.radians(p["upright_pitch_deg"])) ** 2)),
        ZUPT_DZ=int(round(d2(p["zupt_dz_cm"]))),
        ZUPT_DZ_SHORT=int(round(d2(p["zupt_dz_short_cm"]))),
        MOVE=int(round(d2(p["move_cm"]))),
        INWARD_TAN_X1000=int(round(1000 * math.tan(math.radians(p["inward_half_deg"])))),
        CROSS_TAN_X1000=int(round(1000 * math.tan(math.radians(-p["cross_roll_deg"])))),
        KICK_PITCH=int(round(deg_sum(p["kick_pitch_deg"]))),
        KICK_RANGE=int(round(deg_sum(p["kick_range_deg"]))),
        KICK_Z=int(round(d2(p["kick_z_cm"]))),
        KICK_PITCH2=int(round(deg_sum(p["kick_pitch2_deg"]))),
        KICK_DROP=int(round(d2(p["kick_drop_cm"]))),
        KICK_LOW_PITCH=int(round(deg_sum(p["kick_low_pitch_deg"]))),
        KICK_LOW=int(round(d2(p["kick_low_cm"]))),
    )


T = thresholds()
CM_PER_D2 = _cm_per_d2()
DEG_PER_SUM = GYR_LSB_DPS / ODR_HZ


def _ddsum2(acc: list, k: int, e: int) -> int:
    """Twice the double sum of acc over samples k+1..e with the velocity linearly
    de-drifted to zero at e (zero at k by construction). Exact integer."""
    m = e - k
    v = 0; sv = 0
    for i in range(k + 1, e + 1):
        v += acc[i]; sv += v
    return 2 * sv - v * (m + 1)


def features(w: np.ndarray, T: dict = T) -> dict:
    """All intermediate quantities, in window units and in physical units."""
    x = [[int(c) for c in row] for row in np.asarray(w, dtype=np.int8)]
    n = WIN_LEN; S = WIN_PRE
    ax = [r[0] for r in x]; ay = [r[1] for r in x]; az = [r[2] for r in x]
    gx = [r[3] for r in x]; gy = [r[4] for r in x]; gz = [r[5] for r in x]
    fx = [r[6] for r in x]; fy = [r[7] for r in x]; fz = [r[8] for r in x]
    sm2 = [ax[i] ** 2 + ay[i] ** 2 + az[i] ** 2 for i in range(n)]
    gm2 = [gx[i] ** 2 + gy[i] ** 2 + gz[i] ** 2 for i in range(n)]
    aw2 = [fx[i] ** 2 + fy[i] ** 2 + fz[i] ** 2 for i in range(n)]
    upright = [100 * ax[i] ** 2 < T["UPRIGHT_SIN2_X100"] * sm2[i] for i in range(n)]

    # 1. landing
    imp = S
    for j in range(min(S + 3, n - 2), S - T["IMPACT_BACK"] - 1, -1):
        if sm2[j] >= T["IMPACT2"] and sm2[j] >= sm2[j - 1] and sm2[j] >= sm2[j + 1]:
            imp = j
            break
    # 2. end ZUPT
    planted = [aw2[i] < T["PLANT_A2"] and gm2[i] < T["PLANT_G2"] for i in range(n)]
    e = n - 1
    for i in range(imp + 1, n - 2):
        if planted[i] and planted[i + 1] and planted[i + 2]:
            e = i
            break
    # 3. start ZUPT
    kpk = -1
    for i in range(imp - 1, -1, -1):
        if gm2[i] >= T["SWING_G2"]:
            kpk = i
            break
    if kpk < 0:
        for i in range(imp - 1, -1, -1):
            if gm2[i] >= T["SWING_LOW_G2"]:
                kpk = i
                break
    if kpk < 0:
        kpk = max(imp - 5, 0)
    quiet = [g < T["QUIET_G2"] for g in gm2]
    hw = QUIET_HW
    s = -1; best = -1; best_dz = 0; how = 0      # how: 0 ZUPT, 1 nearest height, 2 quietest
    k = min(kpk, n - hw - 1, e - 1)
    while k >= hw:
        q5 = all(quiet[k - hw:k + hw + 1])
        q3 = quiet[k - 1] and quiet[k] and quiet[k + 1]     # short stance between quick steps
        if (q5 or q3) and upright[k]:
            dz = abs(_ddsum2(fz, k, e))
            if q5 and (best < 0 or dz < best_dz):
                best, best_dz = k, dz
            if dz < (T["ZUPT_DZ"] if q5 else T["ZUPT_DZ_SHORT"]):
                s = k
                break
            while k >= hw and (all(quiet[k - hw:k + hw + 1]) if q5 else (quiet[k - 1] and quiet[k] and quiet[k + 1])):
                k -= 1
        k -= 1
    if s < 0 and best >= 0:
        s = best; how = 1
    if s < 0:
        how = 2
        s = max(min(kpk, e) - 1, 0); bv = -1
        for k in range(max(hw, kpk - FALLBACK_BACK), min(kpk, e, n - hw)):
            v = max(gm2[k - hw:k + hw + 1]) + (0 if upright[k] else 1 << 20)
            if bv < 0 or v < bv:
                bv, s = v, k
    m = e - s

    # 4. de-drifted displacement (doubled), peak height (doubled × m), pitch
    X = _ddsum2(fx, s, e)
    Y = _ddsum2(fy, s, e)
    Z = _ddsum2(fz, s, e)
    vz_end = sum(fz[s + 1:e + 1])
    v = 0; sv = 0; zmax_2m = 0
    for j, i in enumerate(range(s + 1, e + 1), start=1):
        v += fz[i]; sv += v
        zmax_2m = max(zmax_2m, 2 * m * sv - vz_end * j * (j + 1))
    th = 0; pmin = 0
    for i in range(s + 1, e + 1):
        th += gy[i]; pmin = min(pmin, th)
    th = 0; tmin = 0; tmax = 0
    for i in range(0, imp + 1):
        th += gy[i]; tmin = min(tmin, th); tmax = max(tmax, th)
    prange = tmax - tmin
    r1 = min(e + ROLL_SAMPLES, n)
    ay_s = sum(ay[e:r1]); az_s = sum(az[e:r1])

    return dict(imp=imp, e=e, kpk=kpk, s=s, how=how, X=X, Y=Y, Z=Z, zmax_2m=zmax_2m, m=m,
                pmin=pmin, prange=prange, ay_s=ay_s, az_s=az_s,
                dx_cm=X * CM_PER_D2, dy_cm=Y * CM_PER_D2, dz_cm=Z * CM_PER_D2,
                zmax_cm=(zmax_2m / m * CM_PER_D2) if m else 0.0,
                pmin_deg=pmin * DEG_PER_SUM, prange_deg=prange * DEG_PER_SUM,
                roll_deg=math.degrees(math.atan2(ay_s, az_s)) if az_s else 0.0,
                swing_ms=m * 1000 / ODR_HZ)


def decide(f: dict, T: dict = T) -> tuple[StepClass, int]:
    """Class and confidence from features(). Confidence is 128 + the smallest
    margin to a decision boundary (0..127), so a borderline call is < 160 and the
    judge does not count it as a wrong step."""
    X, Y, m = f["X"], f["Y"], f["m"]
    d2 = X * X + Y * Y
    if (f["pmin"] <= -T["KICK_PITCH"] or f["prange"] >= T["KICK_RANGE"]
            or (f["Z"] <= -T["KICK_DROP"] and f["how"] < 2)     # a quiet start, but in the air
            or (f["zmax_2m"] >= T["KICK_Z"] * m and f["pmin"] <= -T["KICK_PITCH2"])
            or (f["pmin"] <= -T["KICK_LOW_PITCH"] and d2 < T["KICK_LOW"] * T["KICK_LOW"])):
        return StepClass.KICK, 230
    mv2 = T["MOVE"] * T["MOVE"]
    if d2 < mv2:
        return StepClass.IN_PLACE, 128 + 127 * (mv2 - d2) // mv2
    md = min(127, 127 * (d2 - mv2) // (3 * mv2))
    ax_, ay_ = abs(X), abs(Y)
    tin = T["INWARD_TAN_X1000"]
    if Y < 0 and 1000 * ax_ <= tin * ay_:
        ma = 127 * (tin * ay_ - 1000 * ax_) // (tin * ay_ + 1000 * ax_)
        az_s = max(f["az_s"], 1)
        r = 1000 * f["ay_s"] + T["CROSS_TAN_X1000"] * az_s     # tan(roll) <= -tan(6°): cross
        mr = min(127, 127 * abs(r) // (T["CROSS_TAN_X1000"] * az_s))
        return (StepClass.CROSS if r <= 0 else StepClass.SIDE_IN), 128 + min(md, ma, mr)
    if ax_ >= ay_:
        ma = 127 * (ax_ - ay_) // (ax_ + ay_)
        return (StepClass.FORWARD if X > 0 else StepClass.BACK), 128 + min(md, ma)
    ma = 127 * (ay_ - ax_) // (ax_ + ay_)
    return StepClass.SIDE_OUT, 128 + min(md, ma)


def classify(w: np.ndarray) -> tuple[StepClass, int]:
    """w: (WIN_LEN, 9) int8. Returns (class, confidence 0..255)."""
    return decide(features(w))
