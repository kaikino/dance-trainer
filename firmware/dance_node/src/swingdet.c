// Swing-end strike detector; see swingdet.h. Mirrors ml/dt/node.py detect_swing()
// exactly (float32, squared magnitudes, no sqrt), checked on simulated streams by
// ml/tests/test_stepdet_parity.py.
#include "swingdet.h"
#include <string.h>

#define SWD_ACT_GYRO2       (100.0f * 100.0f)   // swing starts: |gyro| > 100 dps ...
#define SWD_ACT_HI2         (1.4f * 1.4f)       // ... or |a| outside 1 ± 0.4 g
#define SWD_ACT_LO2         (0.6f * 0.6f)
#define SWD_STILL_GYRO2     (60.0f * 60.0f)     // planted (no impact): |gyro| < 60 dps,
#define SWD_STILL_ACC2      (0.25f * 0.25f)     //   |a_world| < 0.25 g,
#define SWD_STILL_SOFT      14                  //   14 samples
#define SWD_LOOSE_GYRO2     (200.0f * 200.0f)   // planted right after an impact: < 200 dps,
#define SWD_LOOSE_ACC2      (0.4f * 0.4f)       //   < 0.4 g,
#define SWD_STILL_SAMPLES   6                   //   6 samples
#define SWD_IMPACT2         (1.25f * 1.25f)     // impact: |a| local peak above 1.25 g ...
#define SWD_IMPACT_NEAR     8                   // ... within 8 samples before planting
#define SWD_ANCHOR_BACK     15                  // strike = latest impact this far back
#define SWD_MIN_SWING       12                  // samples; shorter is a bump
#define SWD_MIN_GYRO2       (80.0f * 80.0f)     // slower is not a step
#define SWD_MAX_SWING       160                 // longer motion without planting is dropped
#define SWD_PITCH_SIN2      (0.57f * 0.57f)     // planted shank pitched < 35°
#define SWD_REFRACT_US      200000u

#define H(i) ((i) & (SWD_HIST - 1))

void swingdet_init(swingdet_t *d)
{
    memset(d, 0, sizeof *d);
    d->pending = -1;
}

// Latest local peak of v above thr in [lo, hi] (absolute indexes), or -1.
static int32_t latest_peak(const float *v, uint32_t lo, uint32_t hi, float thr)
{
    for (int64_t j = hi; j >= (int64_t)lo; j--) {
        if (j < 1) break;
        float c = v[H(j)];
        if (c > thr && c >= v[H(j - 1)] && c >= v[H(j + 1)]) return (int32_t)j;
    }
    return -1;
}

int32_t swingdet_feed(swingdet_t *d, uint32_t idx, uint32_t t_us, const float acc[3], const float gyr[3],
                      const float foot[3], bool blanked, int win_post)
{
    float mag2 = acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2];
    float gm2 = gyr[0] * gyr[0] + gyr[1] * gyr[1] + gyr[2] * gyr[2];
    float magw2 = foot[0] * foot[0] + foot[1] * foot[1] + foot[2] * foot[2];
    d->mag2[H(idx)] = mag2;
    d->magw2[H(idx)] = magw2;
    d->t_us[H(idx)] = t_us;

    if (d->pending >= 0) {
        if (idx >= (uint32_t)d->pending + win_post) {
            int32_t a = d->pending;
            d->pending = -1;
            d->last_us = d->t_us[H(a)];
            d->have_last = true;
            return a;
        }
        return -1;
    }
    bool active = !blanked && (gm2 > SWD_ACT_GYRO2 || mag2 > SWD_ACT_HI2 || mag2 < SWD_ACT_LO2);
    bool upright = acc[0] * acc[0] < SWD_PITCH_SIN2 * mag2;
    bool quiet = upright && magw2 < SWD_STILL_ACC2 && gm2 < SWD_STILL_GYRO2;
    bool loose = upright && magw2 < SWD_LOOSE_ACC2 && gm2 < SWD_LOOSE_GYRO2;
    if (!d->moving) {
        if (active) {
            d->moving = true; d->start = idx; d->gpk2 = gm2; d->still_run = 0; d->loose_run = 0;
        }
        return -1;
    }
    if (gm2 > d->gpk2) d->gpk2 = gm2;
    d->still_run = quiet ? d->still_run + 1 : 0;
    d->loose_run = loose ? d->loose_run + 1 : 0;
    bool settled = false;
    uint32_t end = 0;
    if (d->loose_run == SWD_STILL_SAMPLES) {
        end = idx - d->loose_run + 1;
        uint32_t lo = end >= d->start + SWD_IMPACT_NEAR ? end - SWD_IMPACT_NEAR : d->start;
        settled = latest_peak(d->mag2, lo, end, SWD_IMPACT2) >= 0;
    }
    if (!settled && d->still_run >= SWD_STILL_SOFT) {
        end = idx - d->still_run + 1;
        settled = true;
    }
    if (settled) {
        d->moving = false;
        if (end - d->start < SWD_MIN_SWING || d->gpk2 < SWD_MIN_GYRO2) return -1;
        uint32_t lo = end >= d->start + SWD_ANCHOR_BACK ? end - SWD_ANCHOR_BACK : d->start;
        int32_t a = latest_peak(d->mag2, lo, end, SWD_IMPACT2);
        if (a < 0) a = latest_peak(d->magw2, lo, end, 0.0f);   // soft landing: last deceleration
        if (a < 0) a = (int32_t)(end >= d->start + 3 ? end - 3 : d->start);
        if (d->have_last && d->t_us[H(a)] - d->last_us <= SWD_REFRACT_US) return -1;
        if (idx >= (uint32_t)a + win_post) {
            d->last_us = d->t_us[H(a)];
            d->have_last = true;
            return a;
        }
        d->pending = a;
    } else if (idx - d->start > SWD_MAX_SWING) {
        d->moving = false;
    }
    return -1;
}
