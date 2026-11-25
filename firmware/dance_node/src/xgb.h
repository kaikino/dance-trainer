#pragma once
// XGBoost step classifier (ml/train_xgb.py, exported by ml/export_xgb.py into
// xgb_model.h). Inputs: the rule classifier's 8 step features (rules.c) plus
// which foot the node is on. Build with `make CLASSIFIER=xgb`.
#include <stdbool.h>
#include <stdint.h>
#include "rules.h"
#include "stepdet.h"

#ifdef __cplusplus
extern "C" {
#endif

// Class probabilities (softmax of the trees' summed scores) for one step's
// features. probs has DT_CLASS_COUNT entries.
void xgb_probs(const rules_features_t *f, bool right, float *probs);

// The board's call: the most likely class, then the routine's soft limit
// (rules_vocab_neighbour: an allowed step in the adjacent direction may replace
// it; never sure then). confidence = probability x 255. f, if given, gets the
// features.
dt_step_class_t xgb_classify(const step_window_t *w, bool right, uint16_t vocab, uint8_t *confidence,
                             rules_features_t *f);

#ifdef __cplusplus
}
#endif
