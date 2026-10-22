#include "cnn.h"
#include "model_weights.h"
#include <math.h>
#include <string.h>

DT_STATIC_ASSERT(MODEL_WIN_LEN == WIN_LEN && MODEL_CHANNELS == WIN_CHANNELS && MODEL_CLASSES == DT_CLASS_COUNT,
                 "model_weights.h does not match stepdet.h / dt_protocol.h; re-run ml/export.py");

#define POOL_LEN (WIN_LEN / 2)
#define HALF_K   (MODEL_KERNEL / 2)

int cnn_forward(const int8_t x[WIN_LEN][WIN_CHANNELS], float probs[DT_CLASS_COUNT])
{
    // Layer 1: Conv1D "same" + ReLU, then MaxPool(2) fused: compute two conv rows, keep the max.
    static float h1[POOL_LEN][MODEL_CONV1_OUT];
    for (int p = 0; p < POOL_LEN; p++) {
        for (int o = 0; o < MODEL_CONV1_OUT; o++) h1[p][o] = -INFINITY;
        for (int r = 0; r < 2; r++) {
            int t = 2 * p + r;
            for (int o = 0; o < MODEL_CONV1_OUT; o++) {
                float acc = MODEL_B1[o];
                for (int k = 0; k < MODEL_KERNEL; k++) {
                    int ti = t + k - HALF_K;
                    if (ti < 0 || ti >= WIN_LEN) continue;
                    for (int i = 0; i < WIN_CHANNELS; i++) acc += (float)x[ti][i] * MODEL_W1[k][i][o];
                }
                if (acc < 0) acc = 0;
                if (acc > h1[p][o]) h1[p][o] = acc;
            }
        }
    }

    // Layer 2: Conv1D "same" + ReLU, with global average pooling accumulated on the fly.
    float gap[MODEL_CONV2_OUT];
    memset(gap, 0, sizeof gap);
    for (int t = 0; t < POOL_LEN; t++) {
        for (int o = 0; o < MODEL_CONV2_OUT; o++) {
            float acc = MODEL_B2[o];
            for (int k = 0; k < MODEL_KERNEL; k++) {
                int ti = t + k - HALF_K;
                if (ti < 0 || ti >= POOL_LEN) continue;
                const float *row = h1[ti];
                const float *w = MODEL_W2[k][0] + o;   // W2[k][i][o], stride CONV2_OUT over i
                for (int i = 0; i < MODEL_CONV1_OUT; i++) acc += row[i] * w[i * MODEL_CONV2_OUT];
            }
            if (acc > 0) gap[o] += acc;
        }
    }
    for (int o = 0; o < MODEL_CONV2_OUT; o++) gap[o] /= (float)POOL_LEN;

    // Dense + softmax.
    float logits[DT_CLASS_COUNT], mx = -INFINITY;
    for (int c = 0; c < DT_CLASS_COUNT; c++) {
        float acc = MODEL_B3[c];
        for (int i = 0; i < MODEL_CONV2_OUT; i++) acc += gap[i] * MODEL_W3[i][c];
        logits[c] = acc;
        if (acc > mx) mx = acc;
    }
    float sum = 0;
    for (int c = 0; c < DT_CLASS_COUNT; c++) { probs[c] = expf(logits[c] - mx); sum += probs[c]; }
    int best = 0;
    for (int c = 0; c < DT_CLASS_COUNT; c++) { probs[c] /= sum; if (probs[c] > probs[best]) best = c; }
    return best;
}
