#pragma once
// Rule-based step classifier (MVP and fallback). Mirrors ml/dt/baseline.py, which
// documents the method; integer arithmetic so the two agree exactly.
#include <stdint.h>
#include "stepdet.h"

#ifdef __cplusplus
extern "C" {
#endif

// Everything the rule decided on, for the serial debug print (`rulesdbg on`).
typedef struct {
    int16_t imp, e, s;          // window indexes: landing, end ZUPT, start ZUPT
    uint8_t how;                // start ZUPT: 0 found, 1 nearest landing height, 2 quietest point
    uint8_t how_e;              // end ZUPT: 0 settled, 1 only planted (still moving at the window end)
    float dx_cm, dy_cm, dz_cm;  // de-drifted displacement start→end (+x toe, +y outward)
    float zmax_cm;              // highest point of the swing
    float pitch_min_deg;        // most toe-up shank pitch during the swing (negative)
    float pitch_range_deg;      // shank pitch span over the window up to the landing
    float roll_deg;             // shank roll after landing (negative = leaning inward)
    float swing_ms;             // start → end ZUPT
} rules_features_t;

dt_step_class_t rules_classify_ex(const step_window_t *w, uint16_t vocab, uint8_t *confidence, rules_features_t *f);

// The routine-vocabulary substitution rules_classify() applies, for another
// classifier's call: an allowed travelling class within the adjacent sector of
// `cls` (by nominal direction), best by `score` (higher better), or `cls` itself.
dt_step_class_t rules_vocab_neighbour(dt_step_class_t cls, uint16_t vocab, const float *score);

#ifdef __cplusplus
}
#endif
