#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void haptic_init(void);              // motor GPIO low
void haptic_task(void *arg);         // haptic_q → patterns on the motor pin
// True if a sample taken at t_us falls inside a buzz or its settling time, so
// the strike detector ignores motor vibration (see stepdet.c).
bool haptic_blanked(uint32_t t_us);

#ifdef __cplusplus
}
#endif
