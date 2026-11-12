#pragma once
// Swing-end strike detector: one event per swing, anchored at the landing.
// Pure C (no RTOS) so ml/tests/test_stepdet_parity.py can run it on the host
// against ml/dt/node.py detect_swing(). Used by stepdet.c detect_task().
//
// A swing starts when the shank moves (|gyro| > 100 dps or ||a| - 1 g| > 0.4 g).
// It ends when the foot is planted: right after an impact (|a| local peak
// > 1.25 g within 8 samples) a loose test is enough (|a_world| < 0.4 g,
// |gyro| < 200 dps, 6 samples; weight transfer keeps rolling the shank); without
// one it takes 14 samples of |a_world| < 0.25 g and |gyro| < 60 dps (a coast at
// mid-swing is shorter). Planted also needs the shank pitched < 35° (a kick held
// in the air is not planted). The strike is the latest impact in the 15 samples
// before planting, else the last deceleration peak. Swings shorter than 12
// samples or slower than 80 dps are bumps (the other foot landing), not steps.
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SWD_HIST 64   // samples of history kept for the look-back (power of two)

typedef struct {
    bool moving;
    uint32_t start;          // sample index where the swing started
    float gpk2;              // peak |gyro|² in the swing
    int still_run, loose_run;
    int32_t pending;         // anchor waiting for its post-strike samples, or -1
    uint32_t last_us;        // anchor time of the last emitted strike
    bool have_last;
    float mag2[SWD_HIST], magw2[SWD_HIST];
    uint32_t t_us[SWD_HIST];
} swingdet_t;

void swingdet_init(swingdet_t *d);

// Feed consecutive samples (idx = absolute sample count). acc/gyr: calibrated
// sensor frame (g, dps); foot: foot-frame accel, gravity removed (g). blanked:
// the haptic motor is running, so this sample cannot start a swing. Returns the
// anchor index of a strike whose window (win_post samples after it) is complete
// now, else -1.
int32_t swingdet_feed(swingdet_t *d, uint32_t idx, uint32_t t_us, const float acc[3], const float gyr[3],
                      const float foot[3], bool blanked, int win_post);

#ifdef __cplusplus
}
#endif
