#include "judge.h"
#include "model.h"
#include "stepdet.h"
#include <stdlib.h>
#include <string.h>
#include "dt_port.h"
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

static const char *TAG = "judge";
extern QueueHandle_t window_q, haptic_q, event_q;

typedef struct {
    uint32_t t_us;        // absolute node time of this beat
    uint8_t  cls;
    bool     matched;
    bool     reported_missed;
} sched_step_t;

static struct {
    dt_mode_t mode;
    uint32_t t0_us;
    uint16_t bpm_x10;
    uint16_t n;
    sched_step_t steps[DT_SCHED_MAX_STEPS];
    uint16_t pending_n;                  // steps received so far during a push
    dt_sched_step_t pending[DT_SCHED_MAX_STEPS];
    uint8_t  threshold;
    uint16_t window_ms;
    uint16_t seq;
} J;

void judge_init(void)
{
    memset(&J, 0, sizeof J);
    J.threshold = 160;
    J.window_ms = 150;
}

void judge_schedule_begin(const dt_sched_header_t *h)
{
    J.bpm_x10 = h->bpm_x10;
    J.pending_n = 0;
    DT_LOGI(TAG, "schedule preset=%u bpm=%.1f steps=%u", h->preset_id, h->bpm_x10 / 10.0f, h->n_steps);
}

void judge_schedule_add(const dt_sched_step_t *s, int n)
{
    for (int i = 0; i < n && J.pending_n < DT_SCHED_MAX_STEPS; i++) J.pending[J.pending_n++] = s[i];
}

void judge_start(dt_mode_t mode, uint32_t t0_node_us)
{
    J.mode = mode;
    J.t0_us = t0_node_us;
    J.seq = 0;
    J.n = J.pending_n;
    float beat_us = 60e6f / (J.bpm_x10 / 10.0f);
    for (int i = 0; i < J.n; i++) {
        J.steps[i].t_us = t0_node_us + (uint32_t)((J.pending[i].beat_x100 / 100.0f - 1.0f) * beat_us);
        J.steps[i].cls = J.pending[i].step_class;
        J.steps[i].matched = false;
        J.steps[i].reported_missed = false;
    }
    DT_LOGI(TAG, "start mode=%d t0=%lu n=%u", mode, (unsigned long)t0_node_us, J.n);
}

void judge_stop(void) { J.mode = DT_MODE_IDLE; }
void judge_set_threshold(uint8_t c) { J.threshold = c; }
void judge_set_window(uint16_t ms) { J.window_ms = ms; }
dt_mode_t judge_mode(void) { return J.mode; }

static void emit(dt_step_event_t *e, uint8_t haptic)
{
    e->seq = J.seq++;
    if (xQueueSend(event_q, e, 0) != pdTRUE) DT_LOGW(TAG, "event_q full");
    if (haptic) xQueueSend(haptic_q, &haptic, 0);
}

// Nearest unmatched scheduled step within ±window of t. Returns index or -1.
static int nearest(uint32_t t)
{
    int best = -1; int32_t best_d = 0;
    for (int i = 0; i < J.n; i++) {
        if (J.steps[i].matched) continue;
        int32_t d = (int32_t)(t - J.steps[i].t_us) / 1000;
        if (abs(d) <= J.window_ms * 2 && (best < 0 || abs(d) < abs(best_d))) { best = i; best_d = d; }
    }
    return best;
}

static void judge_step(const step_window_t *w)
{
    uint8_t conf;
    dt_step_class_t cls = classify(w, &conf);
    dt_step_event_t e = {
        .t_strike_node_us = w->t_strike_us,
        .step_class = cls, .confidence = conf,
        .expected_class = DT_CLASS_NONE, .timing_err_ms = 0,
        .verdict = DT_VERDICT_UNJUDGED,
    };

    if (J.mode != DT_MODE_DANCE) { emit(&e, 0); return; }

    int i = nearest(w->t_strike_us);
    if (i < 0) { e.verdict = DT_VERDICT_EXTRA; emit(&e, DT_HAPTIC_DOUBLE); return; }

    sched_step_t *s = &J.steps[i];
    s->matched = true;
    e.expected_class = s->cls;
    e.timing_err_ms = (int16_t)((int32_t)(w->t_strike_us - s->t_us) / 1000);

    bool low_conf = conf < J.threshold;
    if (cls != s->cls && !low_conf) {
        e.verdict = DT_VERDICT_WRONG_STEP; emit(&e, DT_HAPTIC_DOUBLE);
    } else if (abs(e.timing_err_ms) > J.window_ms) {
        e.verdict = DT_VERDICT_OFF_BEAT; emit(&e, DT_HAPTIC_SHORT);
    } else {
        e.verdict = DT_VERDICT_CORRECT; emit(&e, 0);
    }
}

// Steps whose window closed with no strike are reported as missed.
static void check_missed(void)
{
    if (J.mode != DT_MODE_DANCE) return;
    uint32_t now = dt_now_us();
    for (int i = 0; i < J.n; i++) {
        sched_step_t *s = &J.steps[i];
        if (s->matched || s->reported_missed) continue;
        if ((int32_t)(now - s->t_us) / 1000 > J.window_ms * 2) {
            s->reported_missed = true;
            dt_step_event_t e = {
                .t_strike_node_us = s->t_us, .step_class = DT_CLASS_NONE, .confidence = 0,
                .expected_class = s->cls, .timing_err_ms = 0, .verdict = DT_VERDICT_MISSED,
            };
            emit(&e, DT_HAPTIC_SHORT);
        }
    }
}

void infer_judge_task(void *arg)
{
    step_window_t w;
    for (;;) {
        if (xQueueReceive(window_q, &w, pdMS_TO_TICKS(50)) == pdTRUE) judge_step(&w);
        check_missed();
    }
}
