#pragma once
// Swing-end strike detector: one event per swing, anchored at the landing.
// Pure C (no RTOS) so ml/tests/test_stepdet_parity.py can run it on the host
// against ml/dt/node.py detect_swing(). Used by stepdet.c detect_task().
//
// A swing starts when the shank or foot moves: |gyro| > 100 dps, ||a| - 1 g| > 0.4 g,
// or |a_world| > 0.3 g (a slide barely turns the shank). It ends when the foot is
// planted, shank pitched < 35° (a kick held in the air is not planted):
//   - after an impact: |a_world| < 0.4 g, |gyro| < 200 dps for 8 samples, with a
//     sensor |a| peak > 1.25 g in the 8 samples before and >= 6 samples into the
//     swing (the push-off peak at lift is not a landing);
//   - without one: |a_world| < 0.25 g, |gyro| < 60 dps for 20 samples (longer
//     than a mid-swing coast).
// It is a step if it lasted >= 12 samples and the foot moved: the integral of
// min(|a_world|, 1.5 g) over the swing >= 0.8 m/s (the other foot landing, or the shank rolling
// over the planted foot, gives far less). Within 30 samples after the last plant
// only an impact ends a step. The strike is the latest impact in the 15 samples
// before planting, else the last deceleration peak; it is emitted win_post samples
// later (the window needs them), so several may be pending at fast tempos.
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SWD_HIST 64   // samples of history kept for the look-back (power of two)
#define SWD_MAX_PEND 4

typedef struct {
    bool moving;
    uint32_t start;          // sample index where the swing started
    int still_run, loose_run;
    float mot;               // ∫|a_world| since the swing started (g·samples)
    float still_sum, loose_sum;   // ... over the current still / loose run
    uint32_t pend[SWD_MAX_PEND];  // anchors waiting for their post-strike samples
    int npend;
    uint32_t last_us;        // anchor time of the last strike
    bool have_last;
    uint32_t last_end;       // plant index of the last strike
    bool have_end;
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
