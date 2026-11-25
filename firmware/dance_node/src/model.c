#include "model.h"
#include "cnn.h"
#include "rules.h"
#include "xgb.h"
#include "dt_port.h"
#include <stdio.h>
#include <stdlib.h>

static dt_step_class_t cnn_classify(const int8_t x[WIN_LEN][WIN_CHANNELS], uint16_t vocab, uint8_t *confidence,
                                    uint32_t *elapsed_us)
{
    float probs[DT_CLASS_COUNT];
    uint32_t t0 = dt_now_us();
    int best = cnn_forward(x, probs);
    *elapsed_us = dt_now_us() - t0;
    *confidence = (uint8_t)(probs[best] * 255.0f + 0.5f);
    // The routine's classes replace an adjacent travelling call, never sure (as the rule).
    dt_step_class_t c = rules_vocab_neighbour((dt_step_class_t)best, vocab, probs);
    if ((int)c != best && *confidence > 159) *confidence = 159;
    return c;
}

#ifdef DT_RULES_DEBUG
static volatile bool rules_dbg = true;
#else
static volatile bool rules_dbg = false;
#endif
void rules_debug_set(bool on) { rules_dbg = on; }
bool rules_debug(void) { return rules_dbg; }

static const char *const class_names[DT_CLASS_COUNT] = {
    "none", "in_place", "forward", "back", "side_out", "cross", "kick", "side_in",
    "forward_out", "forward_in", "back_out", "back_in", "cross_behind",
};

// One line per strike with what the rule saw (docs/bench-check.md). Printed for
// both classifiers, so the CNN can be compared with the rule on the same step.
static void rules_print(const step_window_t *w, uint16_t vocab, dt_step_class_t used, uint8_t used_conf)
{
    rules_features_t f;
    uint8_t rc;
    dt_step_class_t r = rules_classify_ex(w, vocab, &rc, &f);
    printf("rules t=%lu %s conf=%u | dx=%.1f dy=%.1f dz=%.1f cm zmax=%.1f cm pitch=%.0f range=%.0f roll=%.1f deg "
           "swing=%.0f ms zupt=%u settle=%u imp=%d s=%d e=%d | %s=%s %u\n",
           (unsigned long)w->t_strike_us, class_names[r], (unsigned)rc, f.dx_cm, f.dy_cm, f.dz_cm, f.zmax_cm,
           f.pitch_min_deg, f.pitch_range_deg, f.roll_deg, f.swing_ms, (unsigned)f.how, (unsigned)f.how_e, f.imp, f.s, f.e,
           classifier_name(), class_names[used], (unsigned)used_conf);
}

dt_step_class_t classify(const step_window_t *w, uint16_t vocab, uint8_t *confidence)
{
#if defined(DT_CLASSIFIER_RULES)
    dt_step_class_t c = rules_classify(w, vocab, confidence);
#elif defined(DT_CLASSIFIER_XGB)
    dt_step_class_t c = xgb_classify(w, dt_role() == DT_ROLE_RIGHT, vocab, confidence, NULL);
#else
    uint32_t us;
    dt_step_class_t c = cnn_classify(w->x, vocab, confidence, &us);
#endif
    if (rules_dbg) rules_print(w, vocab, c, *confidence);
    return c;
}

const char *classifier_name(void)
{
#if defined(DT_CLASSIFIER_RULES)
    return "rules";
#elif defined(DT_CLASSIFIER_XGB)
    return "xgb";
#else
    return "cnn";
#endif
}

#if __has_include("selftest_vectors.h")
#include "selftest_vectors.h"
void model_selftest(void)
{
    int mismatches = 0;
    printf("selftest: %d windows\nidx,class,conf,us\n", SELFTEST_N);
    for (int i = 0; i < SELFTEST_N; i++) {
        uint8_t conf; uint32_t us;
        dt_step_class_t c = cnn_classify(selftest_x[i], 0, &conf, &us);
        printf("%d,%d,%u,%lu\n", i, (int)c, (unsigned)conf, (unsigned long)us);
        if ((int)c != selftest_expect[i][0] || abs((int)conf - selftest_expect[i][1]) > 2) mismatches++;
    }
    printf("selftest: %d mismatches vs export.py\n", mismatches);
}
#else
void model_selftest(void) { printf("selftest: no selftest_vectors.h; run ml/export.py\n"); }
#endif
