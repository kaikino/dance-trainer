#pragma once
#include <stdint.h>
#include "stepdet.h"

#ifdef __cplusplus
extern "C" {
#endif

// Single entry point used by the judge: the CNN from ml/train.py (cnn.c), or
// the rule classifier when built with -DDT_CLASSIFIER_RULES.
dt_step_class_t classify(const step_window_t *w, uint8_t *confidence);
const char *classifier_name(void);

// Runs the CNN on the embedded test windows and prints idx,class,conf,us over
// serial. Compare with `ml/export.py --selftest`.
void model_selftest(void);

#ifdef __cplusplus
}
#endif
