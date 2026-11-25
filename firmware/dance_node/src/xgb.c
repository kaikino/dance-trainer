#include "xgb.h"
#ifdef XGB_MODEL_HEADER
#include XGB_MODEL_HEADER   // another export (ml/tests/test_xgb_parity.py)
#else
#include "xgb_model.h"
#endif
#include <math.h>

_Static_assert(XGB_N_CLASSES == DT_CLASS_COUNT, "xgb_model.h was exported for a different class list");
_Static_assert(XGB_N_INPUTS == 9, "xgb.c builds 9 inputs: rules_features_t's 8 + is_right");

static float tree_sum(const float *in, int t)
{
    const xgb_node_t *n = &xgb_nodes[xgb_root[t]];
    while (n->feat != XGB_LEAF) {
        const float x = in[n->feat];
        const bool left = isnan(x) ? n->miss_left : x < n->v;       // XGBoost's split rule
        n = &xgb_nodes[n->left + (left ? 0 : 1)];
    }
    return n->v;
}

void xgb_probs(const rules_features_t *f, bool right, float *probs)
{
    // Order: meta.json "inputs" (ml/train_xgb.py INPUTS).
    const float in[XGB_N_INPUTS] = {f->dx_cm, f->dy_cm, f->dz_cm, f->zmax_cm, f->pitch_min_deg,
                                    f->pitch_range_deg, f->roll_deg, f->swing_ms, right ? 1.0f : 0.0f};
    float m[XGB_N_CLASSES];
    for (int c = 0; c < XGB_N_CLASSES; c++) m[c] = xgb_base[c];
    for (int t = 0; t < XGB_N_TREES; t++) m[xgb_class[t]] += tree_sum(in, t);
    float top = m[0], sum = 0;
    for (int c = 1; c < XGB_N_CLASSES; c++) if (m[c] > top) top = m[c];
    for (int c = 0; c < XGB_N_CLASSES; c++) sum += probs[c] = expf(m[c] - top);
    for (int c = 0; c < XGB_N_CLASSES; c++) probs[c] /= sum;
}

dt_step_class_t xgb_classify(const step_window_t *w, bool right, uint16_t vocab, uint8_t *confidence,
                             rules_features_t *f)
{
    rules_features_t own;
    if (!f) f = &own;
    uint8_t rule_conf;
    rules_classify_ex(w, 0, &rule_conf, f);
    float probs[DT_CLASS_COUNT];
    xgb_probs(f, right, probs);
    int best = 0;
    for (int c = 1; c < DT_CLASS_COUNT; c++) if (probs[c] > probs[best]) best = c;
    *confidence = (uint8_t)(probs[best] * 255.0f + 0.5f);
    dt_step_class_t c = rules_vocab_neighbour((dt_step_class_t)best, vocab, probs);
    if ((int)c != best && *confidence > 159) *confidence = 159;   // replaced by the routine: never sure
    return c;
}
