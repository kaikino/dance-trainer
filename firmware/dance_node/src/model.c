#include "model.h"
#include "cnn.h"
#include "dt_port.h"
#include <stdio.h>
#include <stdlib.h>

static dt_step_class_t cnn_classify(const int8_t x[WIN_LEN][WIN_CHANNELS], uint8_t *confidence, uint32_t *elapsed_us)
{
    float probs[DT_CLASS_COUNT];
    uint32_t t0 = dt_now_us();
    int best = cnn_forward(x, probs);
    *elapsed_us = dt_now_us() - t0;
    *confidence = (uint8_t)(probs[best] * 255.0f + 0.5f);
    return (dt_step_class_t)best;
}

dt_step_class_t classify(const step_window_t *w, uint8_t *confidence)
{
#ifdef DT_CLASSIFIER_RULES
    return rules_classify(w, confidence);
#else
    uint32_t us;
    return cnn_classify(w->x, confidence, &us);
#endif
}

const char *classifier_name(void)
{
#ifdef DT_CLASSIFIER_RULES
    return "rules";
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
        dt_step_class_t c = cnn_classify(selftest_x[i], &conf, &us);
        printf("%d,%d,%u,%lu\n", i, (int)c, (unsigned)conf, (unsigned long)us);
        if ((int)c != selftest_expect[i][0] || abs((int)conf - selftest_expect[i][1]) > 2) mismatches++;
    }
    printf("selftest: %d mismatches vs export.py\n", mismatches);
}
#else
void model_selftest(void) { printf("selftest: no selftest_vectors.h; run ml/export.py\n"); }
#endif
