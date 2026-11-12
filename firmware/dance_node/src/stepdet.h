#pragma once
#include <stdint.h>
#include "dt_protocol.h"

// Window geometry. Must match ml/dt/windows.py exactly.
#ifdef __cplusplus
extern "C" {
#endif

#define WIN_PRE_SAMPLES   100  // ≈0.96 s before the strike (104 Hz): a slow swing and the stance before it
#define WIN_POST_SAMPLES  40   // ≈0.38 s after: the foot settling (heel drop, weight transfer)
#define WIN_LEN           (WIN_PRE_SAMPLES + WIN_POST_SAMPLES)   // 140
#define WIN_CHANNELS      9    // ax ay az gx gy gz (sensor) + ax ay az (world)
// A strike's window reaches the judge WIN_POST_SAMPLES after the landing (swingdet.c
// emits exactly then: it has always decided by anchor + 35 samples), plus queueing
// and classification. judge.c waits this long before calling a step missed.
#define DETECT_LATENCY_MS ((WIN_POST_SAMPLES * 1000 + 103) / 104 + 60)

typedef struct {
    uint32_t t_strike_us;
    int8_t   x[WIN_LEN][WIN_CHANNELS];   // quantized with scales from model_scales.h
} step_window_t;

// Strike detection: swingdet.c (one strike per swing, at the landing, once the
// foot is planted). Its constants live there; ml/dt/node.py mirrors them.
void detect_task(void *arg);   // scans the fusion ring, emits step_window_t to window_q

// Rule-based classifier (MVP, and fallback). Returns class + confidence 0..255.
// rules.h has the variant that also returns its features.
dt_step_class_t rules_classify(const step_window_t *w, uint8_t *confidence);

#ifdef __cplusplus
}
#endif
