"""Rule-based step classifier. Must match firmware rules.c exactly (integer
arithmetic throughout, so the two agree bit for bit; tests/test_rules_parity.py).

Pedestrian-dead-reckoning on one int8 window (dt/windows.py), in physical units:

  1. Landing: the latest sensor |a| peak >= 1.25 g near the strike index (the
     detector anchors there; this re-finds it if the anchor drifted).
  2. End ZUPT: the first sample after the landing from which the foot stays
     settled (|a_world| < 0.2 g, |gyro| < 60 dps) for 5 samples, so a heel drop
     after a ball landing and the shank rolling over the new stance foot are over
     (the window runs 40 samples past the strike for this); else the first planted
     sample (< 0.4 g, < 200 dps for 3).
  3. Start ZUPT: walking back from the last fast shank rotation (>= 100 dps)
     before the landing, the latest sample that is gyro-quiet (< 40 dps for 5
     samples, or 3 with |dz| < 1 cm: a short stance between quick steps) with the
     shank upright (pitch < 35°), AND from which the foot ends at the same height
     (|dz| < 3.5 cm). A pause at peak lift or a kick apex is quiet too, but the
     foot then drops by the lift height, so it is skipped.
  4. Integrate foot-frame accel from start to end with zero velocity at both
     ends (linear velocity de-drift): constant accel bias and leaked gravity
     (tilt error) cancel exactly, whatever the swing length or tempo. The sensor
     sits ~9 cm up the shank, which may still rotate at either ZUPT; the velocity
     that puts there (omega x r) is added back.
  5. Classify on the horizontal displacement direction (angle sectors) and
     distance in cm; kick from shank pitch (gyro) and foot height, for a toe-up
     swing that comes back near where it left (a step that swings the shank as
     far travels); cross vs side_in from the shank roll right after landing (a
     crossing foot lands past the standing one, so its shank leans inward, roll
     <= -5°; a close lands under its hip). Roll is relative to the calibration
     stance, which is therefore fixed (docs/bench-check.md). Single-node roll
     separates cross and close only ~75-80 % of the time in the auditor's
     simulator, so that call is "sure" only 5° or more from the threshold.
  6. Confidence: 128 + the margin to the nearest boundary, 160 (the judge's
     default) only where the simulators say the call is safe (decide()).

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
    settle_g=0.2,           # end ZUPT: the foot has settled: |a_world| below ...
    settle_dps=60.0,        # ... and |gyro| below, SETTLE_N samples in a row (heel drop and
                            # the shank rolling over the new stance foot are over)
    planted_g=0.4,          # fallback end ZUPT if it never settles in the window: |a_world| below
    planted_dps=200.0,      # ... and |gyro| below, 3 samples in a row
    lever_cm=9.0,           # sensor height above the ankle: the shank still rotates at the
                            # ZUPTs, so the sensor moves at omega x r there, not 0
    swing_dps=100.0,        # shank rotation that marks the swing (60 if none reaches it)
    swing_dps_low=60.0,
    quiet_dps=40.0,         # start ZUPT: |gyro| below this for 2*QUIET_HW+1 samples
    upright_pitch_deg=35.0,
    zupt_dz_cm=3.5,         # start ZUPT must be at landing height
    zupt_dz_short_cm=1.0,   # ... tighter when only 3 samples are quiet (a short stance, or a pause mid-swing)
    move_cm=6.0,            # below: in place
    sure_still_cm=4.0,      # confidence: in place is sure below this ...
    sure_move_cm=9.0,       # ... a step is sure above this (estimates are good to a few cm)
    inward_half_deg=55.0,   # inward sector half-width around -y (crosses land in front/behind)
    cross_roll_deg=-5.0,    # shank roll after landing at or below this: cross
    sure_roll_deg=5.0,      # confidence: cross/close are sure this far from cross_roll_deg
    kick_pitch_deg=28.0,    # shank swings forward (toe up) at least this much ...
    kick_back_cm=25.0,      # ... and the foot comes back within this (a step travels)
    kick_far_pitch_deg=40.0,  # ... or swings this far whatever the travel
    kick_range_deg=55.0,    # or the shank pitch spans this much in the swing (and comes back)
    kick_z_cm=15.0,         # or the foot rises this high while swinging forward kick_pitch2
    kick_pitch2_deg=20.0,
    kick_drop_cm=15.0,      # or the integration had to start in the air (a held kick)
    kick_low_pitch_deg=18.0,  # or a low kick: toe-up at least this much ...
    kick_low_cm=15.0,         # ... back down within this of where it left ...
    kick_low_z_cm=4.0,        # ... after lifting at least this high (a toe-up stamp does not)
    sure_kick_pitch_deg=35.0,  # confidence: a kick is sure from this pitch or kick_z_cm height
)
QUIET_HW = 2
SETTLE_N = 5
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
        SETTLE_A2=int(round(a(p["settle_g"]) ** 2)),
        SETTLE_G2=int(round(w(p["settle_dps"]) ** 2)),
        PLANT_A2=int(round(a(p["planted_g"]) ** 2)),
        PLANT_G2=int(round(w(p["planted_dps"]) ** 2)),
        SWING_G2=int(round(w(p["swing_dps"]) ** 2)),
        SWING_LOW_G2=int(round(w(p["swing_dps_low"]) ** 2)),
        QUIET_G2=int(round(w(p["quiet_dps"]) ** 2)),
        # lever: dx += (gy_s3 + gy_e3) * m * LEVER_X1000 / 3000 (3-sample gyro sums at both ZUPTs)
        LEVER_X1000=int(round(1000 * GYR_LSB_DPS * math.pi / 180 * p["lever_cm"] / 2 / ODR_HZ / _cm_per_d2())),
        UPRIGHT_SIN2_X100=int(round(100 * math.sin(math.radians(p["upright_pitch_deg"])) ** 2)),
        ZUPT_DZ=int(round(d2(p["zupt_dz_cm"]))),
        ZUPT_DZ_SHORT=int(round(d2(p["zupt_dz_short_cm"]))),
        MOVE=int(round(d2(p["move_cm"]))),
        SURE_STILL=int(round(d2(p["sure_still_cm"]))),
        SURE_MOVE=int(round(d2(p["sure_move_cm"]))),
        INWARD_TAN_X1000=int(round(1000 * math.tan(math.radians(p["inward_half_deg"])))),
        CROSS_TAN_X1000=int(round(1000 * math.tan(math.radians(-p["cross_roll_deg"])))),
        ROLL_BAND_X1000=int(round(1000 * (math.tan(math.radians(-p["cross_roll_deg"] + p["sure_roll_deg"]))
                                          - math.tan(math.radians(-p["cross_roll_deg"]))))),
        KICK_PITCH=int(round(deg_sum(p["kick_pitch_deg"]))),
        KICK_BACK=int(round(d2(p["kick_back_cm"]))),
        KICK_FAR_PITCH=int(round(deg_sum(p["kick_far_pitch_deg"]))),
        KICK_RANGE=int(round(deg_sum(p["kick_range_deg"]))),
        KICK_Z=int(round(d2(p["kick_z_cm"]))),
        KICK_PITCH2=int(round(deg_sum(p["kick_pitch2_deg"]))),
        KICK_DROP=int(round(d2(p["kick_drop_cm"]))),
        KICK_LOW_PITCH=int(round(deg_sum(p["kick_low_pitch_deg"]))),
        KICK_LOW=int(round(d2(p["kick_low_cm"]))),
        KICK_LOW_Z=int(round(d2(p["kick_low_z_cm"]))),
        SURE_KICK_PITCH=int(round(deg_sum(p["sure_kick_pitch_deg"]))),
    )


T = thresholds()
CM_PER_D2 = _cm_per_d2()
DEG_PER_SUM = GYR_LSB_DPS / ODR_HZ


def _cdiv(a: int, b: int) -> int:
    """Integer division truncating toward zero, as C does."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


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
    # 2. end ZUPT: the first sample after the landing from which the foot stays settled
    #    for SETTLE_N samples; if it never does in the window, the first planted one.
    settled = [aw2[i] < T["SETTLE_A2"] and gm2[i] < T["SETTLE_G2"] for i in range(n)]
    planted = [aw2[i] < T["PLANT_A2"] and gm2[i] < T["PLANT_G2"] for i in range(n)]
    e = -1; how_e = 0
    for i in range(imp + 1, n - SETTLE_N + 1):
        if all(settled[i:i + SETTLE_N]):
            e = i
            break
    if e < 0:
        how_e = 1; e = n - 1
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
    # The ZUPTs hold the ankle still, not the sensor LEVER above it: the shank may still
    # rotate there (weight transfer), moving the sensor at omega x r. Add back the
    # displacement the zero-velocity assumption removed: (v_s + v_e) / 2 * T, with
    # v = (gy, -gx) * r in the sensor frame (≈ the foot frame while standing).
    gys = sum(gy[max(s - 1, 0):s + 2]) + sum(gy[e - 1:min(e + 2, n)])
    gxs = sum(gx[max(s - 1, 0):s + 2]) + sum(gx[e - 1:min(e + 2, n)])
    X = _ddsum2(fx, s, e) + _cdiv(gys * (e - s) * T["LEVER_X1000"], 3000)
    Y = _ddsum2(fy, s, e) - _cdiv(gxs * (e - s) * T["LEVER_X1000"], 3000)
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
    for i in range(s + 1, imp + 1):
        th += gy[i]; tmin = min(tmin, th); tmax = max(tmax, th)
    prange = tmax - tmin
    r1 = min(e + ROLL_SAMPLES, n)
    ay_s = sum(ay[e:r1]); az_s = sum(az[e:r1])

    return dict(imp=imp, e=e, kpk=kpk, s=s, how=how, how_e=how_e, X=X, Y=Y, Z=Z, zmax_2m=zmax_2m, m=m,
                pmin=pmin, prange=prange, ay_s=ay_s, az_s=az_s,
                dx_cm=X * CM_PER_D2, dy_cm=Y * CM_PER_D2, dz_cm=Z * CM_PER_D2,
                zmax_cm=(zmax_2m / m * CM_PER_D2) if m else 0.0,
                pmin_deg=pmin * DEG_PER_SUM, prange_deg=prange * DEG_PER_SUM,
                roll_deg=math.degrees(math.atan2(ay_s, az_s)) if az_s else 0.0,

                swing_ms=m * 1000 / ODR_HZ)


SURE = 32   # margin at which a call is sure: confidence 128 + 32 = 160, the judge's default


def decide(f: dict, T: dict = T) -> tuple[StepClass, int]:
    """Class and confidence from features(). Confidence is 128 + the smallest margin
    to a decision boundary, scaled so that SURE (32, confidence 160 = the judge's
    default threshold) is reached only where the simulators say the call is safe:
    a step within ~2-3 cm of the in-place threshold, within 5° of the cross roll,
    within 14° of a direction boundary, or a low kick, stays below 160, so judge.c
    does not score it as a wrong step. All operands are non-negative where divided
    (C and Python integer division agree)."""
    X, Y, m = f["X"], f["Y"], f["m"]
    pmin, zmax_2m = f["pmin"], f["zmax_2m"]
    d2 = X * X + Y * Y
    back = d2 < T["KICK_BACK"] * T["KICK_BACK"]
    high = zmax_2m >= T["KICK_Z"] * m
    if ((pmin <= -T["KICK_PITCH"] and (back or pmin <= -T["KICK_FAR_PITCH"]))
            or (f["prange"] >= T["KICK_RANGE"] and (back or f["how"] > 0))   # far: only if not a clean start
            or (f["Z"] <= -T["KICK_DROP"] and f["how"] == 0)     # a quiet start, but in the air
            or (high and pmin <= -T["KICK_PITCH2"])
            or (pmin <= -T["KICK_LOW_PITCH"] and d2 < T["KICK_LOW"] * T["KICK_LOW"]
                and zmax_2m >= T["KICK_LOW_Z"] * m)):
        if pmin <= -T["SURE_KICK_PITCH"] or high:
            return StepClass.KICK, 230
        mk = SURE * (-pmin - T["KICK_LOW_PITCH"]) // (T["SURE_KICK_PITCH"] - T["KICK_LOW_PITCH"])
        return StepClass.KICK, 128 + max(0, min(SURE - 1, mk))
    # Not a kick, but close to one: a toe-up swing or a high foot.
    mk = 127
    if pmin < 0 and -pmin > T["KICK_LOW_PITCH"] // 2:
        mk = SURE * (T["KICK_PITCH"] + pmin) // (T["KICK_PITCH"] - T["KICK_LOW_PITCH"] // 2)
        mk = max(0, mk)
    mv2 = T["MOVE"] * T["MOVE"]
    if d2 < mv2:
        lo2 = T["SURE_STILL"] * T["SURE_STILL"]
        mi = SURE * (mv2 - d2) // (mv2 - lo2)
        return StepClass.IN_PLACE, 128 + min(127, mi, mk)
    hi2 = T["SURE_MOVE"] * T["SURE_MOVE"]
    md = min(127, SURE * (d2 - mv2) // (hi2 - mv2))
    ax_, ay_ = abs(X), abs(Y)
    tin = T["INWARD_TAN_X1000"]
    if Y < 0 and 1000 * ax_ <= tin * ay_:
        ma = 127 * (tin * ay_ - 1000 * ax_) // (tin * ay_ + 1000 * ax_)
        az_s = max(f["az_s"], 1)
        r = 1000 * f["ay_s"] + T["CROSS_TAN_X1000"] * az_s     # tan(roll) <= tan(cross_roll): cross
        mr = min(127, SURE * abs(r) // (T["ROLL_BAND_X1000"] * az_s))
        return (StepClass.CROSS if r <= 0 else StepClass.SIDE_IN), 128 + min(md, ma, mr, mk)
    if ax_ >= ay_:
        ma = 127 * (ax_ - ay_) // (ax_ + ay_)
        return (StepClass.FORWARD if X > 0 else StepClass.BACK), 128 + min(md, ma, mk)
    ma = 127 * (ay_ - ax_) // (ax_ + ay_)
    return StepClass.SIDE_OUT, 128 + min(md, ma, mk)


def classify(w: np.ndarray) -> tuple[StepClass, int]:
    """w: (WIN_LEN, 9) int8. Returns (class, confidence 0..255)."""
    return decide(features(w))
