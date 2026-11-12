// Rule-based step classifier: pedestrian dead reckoning on one window.
// Mirrors ml/dt/baseline.py line for line (that file explains the method); all
// decisions are integer arithmetic so the two agree exactly
// (ml/tests/test_rules_parity.py). Summary:
//   landing (sensor |a| peak) → end ZUPT (planted) → start ZUPT (last gyro-quiet,
//   upright moment before the swing, at landing height) → double-integrate the
//   foot-frame accel with zero velocity at both ends → direction sector and
//   distance in cm; kick from shank pitch/height (or toe-up and back where it
//   left); cross vs side_in from the shank roll after landing.
#include "rules.h"
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>

// Thresholds in window units, generated from physical values by
// ml/dt/baseline.py thresholds() (the parity test checks every one):
#define RULE_IMPACT2            394     // (1.25 g)²            landing impact, sensor |a|
#define RULE_IMPACT_BACK        30      // samples              look this far back for it
#define RULE_PLANT_A2           40      // (0.4 g)²             end ZUPT: |a_world| below
#define RULE_PLANT_G2           161     // (200 dps)²           ... and |gyro| below
#define RULE_SWING_G2           40      // (100 dps)²           shank rotation of the swing
#define RULE_SWING_LOW_G2       15      // (60 dps)²            ... if nothing reaches 100
#define RULE_QUIET_G2           6       // (40 dps)²            start ZUPT: gyro quiet
#define RULE_UPRIGHT_SIN2_X100  33      // sin²(35°)·100        start ZUPT: shank pitch < 35°
#define RULE_ZUPT_DZ            1226    // 3.5 cm               start ZUPT at landing height
#define RULE_ZUPT_DZ_SHORT      350     // 1.0 cm               ... if only 3 samples are quiet
#define RULE_MOVE               2101    // 6 cm                 below: in place
#define RULE_INWARD_TAN_X1000   1428    // tan(55°)·1000        inward sector half-width
#define RULE_CROSS_TAN_X1000    70      // tan(4°)·1000         roll <= -4° after landing: cross
#define RULE_KICK_PITCH         185     // 28°                  shank toe-up swing
#define RULE_KICK_RANGE         363     // 55°                  or pitch span in the window
#define RULE_KICK_Z             5253    // 15 cm                or this high ...
#define RULE_KICK_PITCH2        132     // 20°                  ... while pitched this far
#define RULE_KICK_DROP          5253    // 15 cm                or integration started in the air
#define RULE_KICK_LOW_PITCH     119     // 18°                  or a low kick: toe-up this much ...
#define RULE_KICK_LOW           5253    // 15 cm                ... and back down within this

#define QUIET_HW        2
#define FALLBACK_BACK   60
#define ROLL_SAMPLES    8

// Unit conversions for the debug features only (ODR 104 Hz, 8 g and 2000 dps scales).
#define CM_PER_D2       0.002855684783115128f
#define DEG_PER_SUM     0.15142337976983647f

// Twice the double sum of channel c over samples k+1..e, velocity de-drifted to 0 at e.
static int64_t ddsum2(const step_window_t *w, int c, int k, int e)
{
    int64_t v = 0, sv = 0;
    for (int i = k + 1; i <= e; i++) { v += w->x[i][c]; sv += v; }
    return 2 * sv - v * (int64_t)(e - k + 1);
}

static bool all_quiet(const bool *quiet, int k)
{
    for (int i = k - QUIET_HW; i <= k + QUIET_HW; i++) if (!quiet[i]) return false;
    return true;
}

static bool quiet3(const bool *quiet, int k) { return quiet[k - 1] && quiet[k] && quiet[k + 1]; }

static int64_t imin64(int64_t a, int64_t b) { return a < b ? a : b; }
static int64_t imax64(int64_t a, int64_t b) { return a > b ? a : b; }

dt_step_class_t rules_classify_ex(const step_window_t *w, uint8_t *confidence, rules_features_t *f)
{
    const int n = WIN_LEN, S = WIN_PRE_SAMPLES;
    int32_t sm2[WIN_LEN], gm2[WIN_LEN];
    bool upright[WIN_LEN], quiet[WIN_LEN], planted[WIN_LEN];
    for (int i = 0; i < n; i++) {
        const int8_t *r = w->x[i];
        sm2[i] = r[0] * r[0] + r[1] * r[1] + r[2] * r[2];
        gm2[i] = r[3] * r[3] + r[4] * r[4] + r[5] * r[5];
        int32_t aw2 = r[6] * r[6] + r[7] * r[7] + r[8] * r[8];
        upright[i] = 100 * r[0] * r[0] < RULE_UPRIGHT_SIN2_X100 * sm2[i];
        quiet[i] = gm2[i] < RULE_QUIET_G2;
        planted[i] = aw2 < RULE_PLANT_A2 && gm2[i] < RULE_PLANT_G2;
    }

    // 1. landing
    int imp = S;
    for (int j = (S + 3 < n - 2 ? S + 3 : n - 2); j >= S - RULE_IMPACT_BACK; j--) {
        if (sm2[j] >= RULE_IMPACT2 && sm2[j] >= sm2[j - 1] && sm2[j] >= sm2[j + 1]) { imp = j; break; }
    }
    // 2. end ZUPT
    int e = n - 1;
    for (int i = imp + 1; i < n - 2; i++) {
        if (planted[i] && planted[i + 1] && planted[i + 2]) { e = i; break; }
    }
    // 3. start ZUPT
    int kpk = -1;
    for (int i = imp - 1; i >= 0; i--) if (gm2[i] >= RULE_SWING_G2) { kpk = i; break; }
    if (kpk < 0) for (int i = imp - 1; i >= 0; i--) if (gm2[i] >= RULE_SWING_LOW_G2) { kpk = i; break; }
    if (kpk < 0) kpk = imp - 5 > 0 ? imp - 5 : 0;

    int s = -1, best = -1, how = 0;
    int64_t best_dz = 0;
    int k = kpk;
    if (k > n - QUIET_HW - 1) k = n - QUIET_HW - 1;
    if (k > e - 1) k = e - 1;
    while (k >= QUIET_HW) {
        // 5 quiet samples, or 3 (a short stance between quick steps) with a tighter height check
        bool q5 = all_quiet(quiet, k), q3 = quiet3(quiet, k);
        if ((q5 || q3) && upright[k]) {
            int64_t dz = llabs(ddsum2(w, 8, k, e));
            if (q5 && (best < 0 || dz < best_dz)) { best = k; best_dz = dz; }
            if (dz < (q5 ? RULE_ZUPT_DZ : RULE_ZUPT_DZ_SHORT)) { s = k; break; }
            while (k >= QUIET_HW && (q5 ? all_quiet(quiet, k) : quiet3(quiet, k))) k--;
        }
        k--;
    }
    if (s < 0 && best >= 0) { s = best; how = 1; }
    if (s < 0) {
        how = 2;
        int hi = kpk < e ? kpk : e;
        s = hi - 1 > 0 ? hi - 1 : 0;
        if (hi > n - QUIET_HW) hi = n - QUIET_HW;
        int64_t bv = -1;
        for (int kk = (kpk - FALLBACK_BACK > QUIET_HW ? kpk - FALLBACK_BACK : QUIET_HW); kk < hi; kk++) {
            int64_t v = 0;
            for (int i = kk - QUIET_HW; i <= kk + QUIET_HW; i++) v = imax64(v, gm2[i]);
            if (!upright[kk]) v += 1 << 20;
            if (bv < 0 || v < bv) { bv = v; s = kk; }
        }
    }
    const int64_t m = e - s;

    // 4. de-drifted displacement (doubled), peak height (doubled × m), pitch, roll
    const int64_t X = ddsum2(w, 6, s, e), Y = ddsum2(w, 7, s, e), Z = ddsum2(w, 8, s, e);
    int64_t vz_end = 0;
    for (int i = s + 1; i <= e; i++) vz_end += w->x[i][8];
    int64_t v = 0, sv = 0, zmax_2m = 0;
    for (int i = s + 1, j = 1; i <= e; i++, j++) {
        v += w->x[i][8]; sv += v;
        zmax_2m = imax64(zmax_2m, 2 * m * sv - vz_end * j * (j + 1));
    }
    int64_t th = 0, pmin = 0;
    for (int i = s + 1; i <= e; i++) { th += w->x[i][4]; pmin = imin64(pmin, th); }
    int64_t tmin = 0, tmax = 0;
    th = 0;
    for (int i = 0; i <= imp; i++) { th += w->x[i][4]; tmin = imin64(tmin, th); tmax = imax64(tmax, th); }
    const int64_t prange = tmax - tmin;
    int64_t ay_s = 0, az_s = 0;
    for (int i = e; i < e + ROLL_SAMPLES && i < n; i++) { ay_s += w->x[i][1]; az_s += w->x[i][2]; }

    if (f) {
        f->imp = imp; f->e = e; f->s = s; f->how = how;
        f->dx_cm = X * CM_PER_D2; f->dy_cm = Y * CM_PER_D2; f->dz_cm = Z * CM_PER_D2;
        f->zmax_cm = m ? zmax_2m / (float)m * CM_PER_D2 : 0;
        f->pitch_min_deg = pmin * DEG_PER_SUM;
        f->pitch_range_deg = prange * DEG_PER_SUM;
        f->roll_deg = az_s ? atan2f((float)ay_s, (float)az_s) * 57.29578f : 0;
        f->swing_ms = m * (1000.0f / 104.0f);
    }

    // 5. decide. Confidence = 128 + smallest margin to a boundary (0..127).
    const int64_t d2 = X * X + Y * Y, mv2 = (int64_t)RULE_MOVE * RULE_MOVE;
    if (pmin <= -RULE_KICK_PITCH || prange >= RULE_KICK_RANGE
        || (Z <= -RULE_KICK_DROP && how < 2)        // a quiet start, but in the air
        || (zmax_2m >= RULE_KICK_Z * m && pmin <= -RULE_KICK_PITCH2)
        || (pmin <= -RULE_KICK_LOW_PITCH && d2 < (int64_t)RULE_KICK_LOW * RULE_KICK_LOW)) {
        *confidence = 230;
        return DT_CLASS_KICK;
    }
    if (d2 < mv2) {
        *confidence = (uint8_t)(128 + 127 * (mv2 - d2) / mv2);
        return DT_CLASS_IN_PLACE;
    }
    const int64_t md = imin64(127, 127 * (d2 - mv2) / (3 * mv2));
    const int64_t ax = llabs(X), ay = llabs(Y), tin = RULE_INWARD_TAN_X1000;
    if (Y < 0 && 1000 * ax <= tin * ay) {
        const int64_t ma = 127 * (tin * ay - 1000 * ax) / (tin * ay + 1000 * ax);
        const int64_t az = az_s > 1 ? az_s : 1;
        const int64_t r = 1000 * ay_s + RULE_CROSS_TAN_X1000 * az;     // <= 0: rolled inward 4° or more
        const int64_t mr = imin64(127, 127 * llabs(r) / (RULE_CROSS_TAN_X1000 * az));
        *confidence = (uint8_t)(128 + imin64(md, imin64(ma, mr)));
        return r <= 0 ? DT_CLASS_CROSS : DT_CLASS_SIDE_IN;
    }
    if (ax >= ay) {
        *confidence = (uint8_t)(128 + imin64(md, 127 * (ax - ay) / (ax + ay)));
        return X > 0 ? DT_CLASS_FORWARD : DT_CLASS_BACK;
    }
    *confidence = (uint8_t)(128 + imin64(md, 127 * (ay - ax) / (ax + ay)));
    return DT_CLASS_SIDE_OUT;
}

dt_step_class_t rules_classify(const step_window_t *w, uint8_t *confidence)
{
    return rules_classify_ex(w, confidence, NULL);
}
