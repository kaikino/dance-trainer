#pragma once
#include <stdint.h>
#include "dt_protocol.h"

// Window geometry. Must match ml/dt/windows.py exactly.
#ifdef __cplusplus
extern "C" {
#endif

#define WIN_PRE_SAMPLES   40   // 400 ms before the strike
#define WIN_POST_SAMPLES  20   // 200 ms after
#define WIN_LEN           (WIN_PRE_SAMPLES + WIN_POST_SAMPLES)   // 60
#define WIN_CHANNELS      9    // ax ay az gx gy gz (sensor) + ax ay az (world)

typedef struct {
    uint32_t t_strike_us;
    int8_t   x[WIN_LEN][WIN_CHANNELS];   // quantized with scales from model_scales.h
} step_window_t;

// Strike detector tuning. Start values; C tunes against recorded data.
#define STRIKE_PEAK_G        1.8f   // |a| above this starts a candidate
#define STRIKE_STILL_G       0.25f  // |a_world| below this for STILL_MS = stance
#define STRIKE_STILL_MS      60
#define STRIKE_REFRACT_MS    200    // no second strike within this

void detect_task(void *arg);   // scans the fusion ring, emits step_window_t to window_q

// Rule-based classifier (MVP, and fallback). Returns class + confidence 0..255.
dt_step_class_t rules_classify(const step_window_t *w, uint8_t *confidence);

#ifdef __cplusplus
}
#endif
