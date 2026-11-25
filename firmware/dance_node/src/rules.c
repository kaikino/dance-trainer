// Rule-based step classifier: pedestrian dead reckoning on one window.
// Mirrors ml/dt/baseline.py line for line (that file explains the method); all
// decisions are integer arithmetic so the two agree exactly
// (ml/tests/test_rules_parity.py). Summary:
//   landing (sensor |a| peak) → end ZUPT (settled for 5 samples) → start ZUPT
//   (last gyro-quiet, upright moment before the swing, at landing height) →
//   double-integrate the foot-frame accel with zero velocity at both ends, plus
//   the lever-arm velocity (shank still rotating) → direction sector and distance
//   in cm; kick from shank pitch/height (toe-up and back near where it left);
//   direction: nearest of 8 sectors (forward, the diagonals, side, back) or a
//   cross in front / behind when the shank rolls inward after landing; the
//   routine's classes (vocab) may replace an adjacent-sector call. Confidence
//   reaches 160 (the judge's default threshold) only away from every boundary.
#include "rules.h"
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdint.h>

// Thresholds in window units, generated from physical values by
// ml/dt/baseline.py thresholds() (the parity test checks every one):
#define RULE_IMPACT2            394     // (1.25 g)²            landing impact, sensor |a|
#define RULE_IMPACT_BACK        30      // samples              look this far back for it
#define RULE_SETTLE_A2          10      // (0.2 g)²             end ZUPT: |a_world| below
#define RULE_SETTLE_G2          15      // (60 dps)²            ... and |gyro| below, 5 samples
#define RULE_PLANT_A2           40      // (0.4 g)²             fallback end ZUPT: |a_world| below
#define RULE_PLANT_G2           161     // (200 dps)²           ... and |gyro| below, 3 samples
#define RULE_SWING_G2           40      // (100 dps)²           shank rotation of the swing
#define RULE_SWING_LOW_G2       15      // (60 dps)²            ... if nothing reaches 100
#define RULE_QUIET_G2           6       // (40 dps)²            start ZUPT: gyro quiet
#define RULE_LEVER_X1000        4165    // 9 cm lever           sensor velocity omega x r at the ZUPTs
#define RULE_UPRIGHT_SIN2_X100  33      // sin²(35°)·100        start ZUPT: shank pitch < 35°
#define RULE_ZUPT_DZ            1226    // 3.5 cm               start ZUPT at landing height
#define RULE_ZUPT_DZ_SHORT      350     // 1.0 cm               ... if only 3 samples are quiet
#define RULE_MIN_SWING          30      // 290 ms               start ZUPT searched at least this long before the landing
#define RULE_MOVE               2101    // 6 cm                 below: in place
#define RULE_SURE_STILL         1401    // 4 cm                 in place is sure below this
#define RULE_SURE_MOVE          3152    // 9 cm                 a step is sure above this
#define RULE_CROSS_OFF_CDEG     2250    // 22.5°                crosses: this far either side of straight inward
#define RULE_CROSS_PEN_CDEG     4500    // 45°                  crossing disagrees with the roll: extra angle
#define RULE_SURE_DIR_CDEG      800     // 8°                   a direction is sure this far inside its sector
#define RULE_VOCAB_REACH_CDEG   6750    // 67.5°                routine classes may replace an adjacent call
#define RULE_CROSS_TAN_X1000    87      // tan(5°)·1000         roll <= -5° after landing: cross
#define RULE_ROLL_BAND_X1000    89      // tan(10°)-tan(5°)     cross/close sure 5° from the threshold
#define RULE_KICK_PITCH         185     // 28°                  shank toe-up swing ...
#define RULE_KICK_BACK          8754    // 25 cm                ... and back within this
#define RULE_KICK_FAR_PITCH     264     // 40°                  ... or toe-up this much anyway
#define RULE_KICK_RANGE         363     // 55°                  or pitch span in the swing
#define RULE_KICK_Z             5253    // 15 cm                or this high ...
#define RULE_KICK_PITCH2        132     // 20°                  ... while pitched this far
#define RULE_KICK_DROP          5253    // 15 cm                or integration started in the air
#define RULE_KICK_LOW_PITCH     119     // 18°                  or a low kick: toe-up this much ...
#define RULE_KICK_LOW           5253    // 15 cm                ... back down within this ...
#define RULE_KICK_LOW_Z         1401    // 4 cm                 ... after lifting this high
#define RULE_SURE_KICK_PITCH    231     // 35°                  a kick is sure from here (or KICK_Z)

#define QUIET_HW        2
#define SETTLE_N        5
#define SURE            32      // margin for confidence 160
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

// Travelling classes: nominal direction (centidegrees of atan2(Y, X), +x toe, +y
// outward) and whether the foot ends past the other one. Order breaks ties and
// must match baseline.py _dirs().
typedef struct { uint8_t cls; int16_t nom; bool crossed; } dir_t;
static const dir_t DIRS[] = {
    {DT_CLASS_FORWARD, 0, false},      {DT_CLASS_FORWARD_OUT, 4500, false},
    {DT_CLASS_SIDE_OUT, 9000, false},  {DT_CLASS_BACK_OUT, 13500, false},
    {DT_CLASS_BACK, 18000, false},     {DT_CLASS_BACK_IN, -13500, false},
    {DT_CLASS_SIDE_IN, -9000, false},  {DT_CLASS_FORWARD_IN, -4500, false},
    {DT_CLASS_CROSS, -9000 + RULE_CROSS_OFF_CDEG, true},
    {DT_CLASS_CROSS_BEHIND, -9000 - RULE_CROSS_OFF_CDEG, true},
};
#define N_DIRS ((int)(sizeof DIRS / sizeof DIRS[0]))

static int32_t adiff(int32_t a, int32_t b)
{
    int32_t d = ((a - b + 18000) % 36000 + 36000) % 36000 - 18000;
    return d < 0 ? -d : d;
}

static int32_t dir_cost(int32_t theta, bool rolled, int i)
{
    return adiff(theta, DIRS[i].nom) + (DIRS[i].crossed != rolled ? RULE_CROSS_PEN_CDEG : 0);
}

// Best and runner-up cost among the directions in vocab (0 = all), Python sorted() order.
static int dir_best(int32_t theta, bool rolled, uint16_t vocab, int32_t *c1, int32_t *c2)
{
    int b = -1; *c1 = INT32_MAX; *c2 = INT32_MAX;
    for (int i = 0; i < N_DIRS; i++) {
        if (vocab && !((vocab >> DIRS[i].cls) & 1)) continue;
        int32_t c = dir_cost(theta, rolled, i);
        if (c < *c1) { *c2 = *c1; *c1 = c; b = i; }
        else if (c < *c2) *c2 = c;
    }
    return b;
}

// Best direction in vocab (0 = all) with its direction margin and roll margin
// (127 if the roll does not change the call): baseline.py direction() pick().
static bool dir_pick(int32_t theta, bool rolled, int64_t mr_raw, uint16_t vocab, int *b, int64_t *ma, int64_t *mr)
{
    int32_t c1, c2, o1, o2;
    *b = dir_best(theta, rolled, vocab, &c1, &c2);
    if (*b < 0) return false;
    int o = dir_best(theta, !rolled, vocab, &o1, &o2);
    *ma = c2 == INT32_MAX ? 127 : imin64(127, SURE * (int64_t)(c2 - c1) / (2 * RULE_SURE_DIR_CDEG));
    *mr = DIRS[o].cls != DIRS[*b].cls ? mr_raw : 127;
    return true;
}

// baseline.py direction(). A call replaced by the routine's classes is never sure.
static dt_step_class_t direction(int64_t X, int64_t Y, int64_t ay_s, int64_t az_s, uint16_t vocab,
                                 int64_t *ma, int64_t *mr)
{
    const int32_t theta = (int32_t)floor(atan2((double)Y, (double)X) * (18000.0 / 3.14159265358979323846) + 0.5);
    const int64_t az = az_s > 1 ? az_s : 1;
    const int64_t r = 1000 * ay_s + RULE_CROSS_TAN_X1000 * az;     // <= 0: rolled inward 5° or more
    const bool rolled = r <= 0;
    const int64_t mr_raw = imin64(127, SURE * llabs(r) / (RULE_ROLL_BAND_X1000 * az));
    int b, vb;
    int64_t vma, vmr;
    dir_pick(theta, rolled, mr_raw, 0, &b, ma, mr);
    if (vocab && !((vocab >> DIRS[b].cls) & 1)
        && dir_pick(theta, rolled, mr_raw, vocab, &vb, &vma, &vmr)
        && adiff(theta, DIRS[vb].nom) <= RULE_VOCAB_REACH_CDEG) {
        *ma = imin64(SURE - 1, vma); *mr = vmr;
        return (dt_step_class_t)DIRS[vb].cls;
    }
    return (dt_step_class_t)DIRS[b].cls;
}

dt_step_class_t rules_classify_ex(const step_window_t *w, uint16_t vocab, uint8_t *confidence, rules_features_t *f)
{
    const int n = WIN_LEN, S = WIN_PRE_SAMPLES;
    int32_t sm2[WIN_LEN], gm2[WIN_LEN];
    bool upright[WIN_LEN], quiet[WIN_LEN], planted[WIN_LEN], settled[WIN_LEN];
    for (int i = 0; i < n; i++) {
        const int8_t *r = w->x[i];
        sm2[i] = r[0] * r[0] + r[1] * r[1] + r[2] * r[2];
        gm2[i] = r[3] * r[3] + r[4] * r[4] + r[5] * r[5];
        int32_t aw2 = r[6] * r[6] + r[7] * r[7] + r[8] * r[8];
        upright[i] = 100 * r[0] * r[0] < RULE_UPRIGHT_SIN2_X100 * sm2[i];
        quiet[i] = gm2[i] < RULE_QUIET_G2;
        planted[i] = aw2 < RULE_PLANT_A2 && gm2[i] < RULE_PLANT_G2;
        settled[i] = aw2 < RULE_SETTLE_A2 && gm2[i] < RULE_SETTLE_G2;
    }

    // 1. landing
    int imp = S;
    for (int j = (S + 3 < n - 2 ? S + 3 : n - 2); j >= S - RULE_IMPACT_BACK; j--) {
        if (sm2[j] >= RULE_IMPACT2 && sm2[j] >= sm2[j - 1] && sm2[j] >= sm2[j + 1]) { imp = j; break; }
    }
    // 2. end ZUPT: settled for SETTLE_N samples, else the first planted sample
    int e = -1, how_e = 0;
    for (int i = imp + 1; i <= n - SETTLE_N && e < 0; i++) {
        bool ok = true;
        for (int j = i; j < i + SETTLE_N; j++) if (!settled[j]) { ok = false; break; }
        if (ok) e = i;
    }
    if (e < 0) {
        how_e = 1; e = n - 1;
        for (int i = imp + 1; i < n - 2; i++) {
            if (planted[i] && planted[i + 1] && planted[i + 2]) { e = i; break; }
        }
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
    if (k > imp - RULE_MIN_SWING) k = imp - RULE_MIN_SWING;   // not a low glide just before the landing
    while (k >= QUIET_HW) {
        // 5 quiet samples, or 3 (a short stance between quick steps) with a tighter height check
        bool q5 = all_quiet(quiet, k), q3 = quiet3(quiet, k);
        if ((q5 || q3) && upright[k]) {
            int64_t dz = llabs(ddsum2(w, 8, k, e));
            if (q5 && (best < 0 || dz < best_dz)) { best = k; best_dz = dz; }
            if (dz < (q5 ? RULE_ZUPT_DZ : RULE_ZUPT_DZ_SHORT)) { s = k; break; }
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
    // The ZUPTs hold the ankle, not the sensor ~9 cm up the shank: add back the
    // displacement of the lever velocity omega x r there, (v_s + v_e) / 2 * T.
    int64_t gys = 0, gxs = 0;
    for (int i = (s - 1 > 0 ? s - 1 : 0); i < s + 2; i++) { gys += w->x[i][4]; gxs += w->x[i][3]; }
    for (int i = e - 1; i < e + 2 && i < n; i++) { gys += w->x[i][4]; gxs += w->x[i][3]; }
    const int64_t X = ddsum2(w, 6, s, e) + gys * (e - s) * RULE_LEVER_X1000 / 3000;
    const int64_t Y = ddsum2(w, 7, s, e) - gxs * (e - s) * RULE_LEVER_X1000 / 3000;
    const int64_t Z = ddsum2(w, 8, s, e);
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
    for (int i = s + 1; i <= imp; i++) { th += w->x[i][4]; tmin = imin64(tmin, th); tmax = imax64(tmax, th); }
    const int64_t prange = tmax - tmin;
    int64_t ay_s = 0, az_s = 0;
    for (int i = e; i < e + ROLL_SAMPLES && i < n; i++) { ay_s += w->x[i][1]; az_s += w->x[i][2]; }

    if (f) {
        f->imp = imp; f->e = e; f->s = s; f->how = how; f->how_e = how_e;
        f->dx_cm = X * CM_PER_D2; f->dy_cm = Y * CM_PER_D2; f->dz_cm = Z * CM_PER_D2;
        f->zmax_cm = m ? zmax_2m / (float)m * CM_PER_D2 : 0;
        f->pitch_min_deg = pmin * DEG_PER_SUM;
        f->pitch_range_deg = prange * DEG_PER_SUM;
        f->roll_deg = az_s ? atan2f((float)ay_s, (float)az_s) * 57.29578f : 0;
        f->swing_ms = m * (1000.0f / 104.0f);
    }

    // 5. decide. Confidence = 128 + smallest margin to a boundary, SURE (32) = 160
    //    only where the call is safe (baseline.py decide()).
    const int64_t d2 = X * X + Y * Y, mv2 = (int64_t)RULE_MOVE * RULE_MOVE;
    const bool back = d2 < (int64_t)RULE_KICK_BACK * RULE_KICK_BACK;
    const bool high = zmax_2m >= RULE_KICK_Z * m;
    if ((pmin <= -RULE_KICK_PITCH && (back || pmin <= -RULE_KICK_FAR_PITCH))
        || (prange >= RULE_KICK_RANGE && (back || how > 0))
        || (Z <= -RULE_KICK_DROP && how == 0)        // a quiet start, but in the air
        || (high && pmin <= -RULE_KICK_PITCH2)
        || (pmin <= -RULE_KICK_LOW_PITCH && d2 < (int64_t)RULE_KICK_LOW * RULE_KICK_LOW
            && zmax_2m >= RULE_KICK_LOW_Z * m)) {
        if (pmin <= -RULE_SURE_KICK_PITCH || high) { *confidence = 230; return DT_CLASS_KICK; }
        int64_t mk = SURE * (-pmin - RULE_KICK_LOW_PITCH) / (RULE_SURE_KICK_PITCH - RULE_KICK_LOW_PITCH);
        *confidence = (uint8_t)(128 + imax64(0, imin64(SURE - 1, mk)));
        return DT_CLASS_KICK;
    }
    int64_t mk = 127;       // not a kick, but a toe-up swing near one
    if (pmin < 0 && -pmin > RULE_KICK_LOW_PITCH / 2)
        mk = imax64(0, SURE * (RULE_KICK_PITCH + pmin) / (RULE_KICK_PITCH - RULE_KICK_LOW_PITCH / 2));
    if (d2 < mv2) {
        const int64_t lo2 = (int64_t)RULE_SURE_STILL * RULE_SURE_STILL;
        *confidence = (uint8_t)(128 + imin64(127, imin64(SURE * (mv2 - d2) / (mv2 - lo2), mk)));
        return DT_CLASS_IN_PLACE;
    }
    const int64_t hi2 = (int64_t)RULE_SURE_MOVE * RULE_SURE_MOVE;
    const int64_t md = imin64(127, SURE * (d2 - mv2) / (hi2 - mv2));
    int64_t ma = 127, mr = 127;
    dt_step_class_t c = direction(X, Y, ay_s, az_s, vocab, &ma, &mr);
    *confidence = (uint8_t)(128 + imin64(imin64(md, ma), imin64(mr, mk)));
    return c;
}

dt_step_class_t rules_vocab_neighbour(dt_step_class_t cls, uint16_t vocab, const float *score)
{
    if (!vocab || ((vocab >> cls) & 1)) return cls;
    int k = -1;
    for (int i = 0; i < N_DIRS; i++) if (DIRS[i].cls == cls) k = i;
    if (k < 0) return cls;                       // none, in place, kick: never replaced
    int best = -1;
    for (int i = 0; i < N_DIRS; i++) {
        if (!((vocab >> DIRS[i].cls) & 1) || adiff(DIRS[k].nom, DIRS[i].nom) > RULE_VOCAB_REACH_CDEG) continue;
        if (best < 0 || score[DIRS[i].cls] > score[DIRS[best].cls]) best = i;
    }
    return best < 0 ? cls : (dt_step_class_t)DIRS[best].cls;
}

dt_step_class_t rules_classify(const step_window_t *w, uint16_t vocab, uint8_t *confidence)
{
    return rules_classify_ex(w, vocab, confidence, NULL);
}
