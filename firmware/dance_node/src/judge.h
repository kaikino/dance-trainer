#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "dt_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

void judge_init(void);

// Called from the BLE task on Schedule / Control writes.
void judge_schedule_begin(const dt_sched_header_t *h);
void judge_schedule_add(const dt_sched_step_t *steps, int n);
void judge_start(dt_mode_t mode, uint32_t t0_node_us);
void judge_stop(void);
void judge_set_threshold(uint8_t conf);
void judge_set_window(uint16_t ms);
dt_mode_t judge_mode(void);

// window_q → classify → verdict → haptic_q + event_q. Also ticks for missed steps.
void infer_judge_task(void *arg);

#ifdef __cplusplus
}
#endif
