#pragma once
// Float inference for the network in ml/train.py build():
//   Conv1D(16,5,same,relu) → MaxPool1D(2) → Conv1D(32,5,same,relu) → GAP → Dense(7,softmax)
// Weights come from model_weights.h (ml/export.py). Input is the int8 window as
// trained: the model sees the raw int8 values as floats, no rescaling.
#include <stdint.h>
#include "stepdet.h"

#ifdef __cplusplus
extern "C" {
#endif

// probs[DT_CLASS_COUNT] receives the softmax output. Returns the argmax class.
int cnn_forward(const int8_t x[WIN_LEN][WIN_CHANNELS], float probs[DT_CLASS_COUNT]);

#ifdef __cplusplus
}
#endif
