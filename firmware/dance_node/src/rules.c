// Rule-based step classifier: integrate world-frame accel over the window to get
// a displacement direction, then threshold. The MVP classifier and the baseline
// the model must beat. Mirrors ml/dt/baseline.py.
#include "stepdet.h"
#include <math.h>

// Displacement thresholds, in the same int8 units as the window. Tune on data.
#define RULE_MOVE_MIN   40.0f   // below this → in_place
#define RULE_KICK_MIN   90.0f   // forward and large → kick

dt_step_class_t rules_classify(const step_window_t *w, uint8_t *confidence)
{
    // Double-integrate world accel (channels 6,7) from window start to strike.
    // Units are arbitrary (int8 × samples²); only ratios and thresholds matter.
    float vx = 0, vy = 0, dx = 0, dy = 0;
    for (int i = 0; i < WIN_PRE_SAMPLES; i++) {
        vx += w->x[i][6]; vy += w->x[i][7];
        dx += vx;         dy += vy;
    }
    dx /= WIN_PRE_SAMPLES; dy /= WIN_PRE_SAMPLES;

    float mag = sqrtf(dx * dx + dy * dy);
    *confidence = (uint8_t)fminf(255.0f, mag * 2.0f);

    if (mag < RULE_MOVE_MIN) { *confidence = 200; return DT_CLASS_IN_PLACE; }

    // Body frame after calibration: +x forward, +y toward the outside of this foot.
    // TODO: left/right mirroring once calibration defines the body frame.
    if (fabsf(dx) >= fabsf(dy)) {
        if (dx > 0) return mag > RULE_KICK_MIN ? DT_CLASS_KICK : DT_CLASS_FORWARD;
        return DT_CLASS_BACK;
    }
    return dy > 0 ? DT_CLASS_SIDE_OUT : DT_CLASS_CROSS;
}
