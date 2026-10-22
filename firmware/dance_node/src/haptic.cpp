// Grove Vibration Motor: coin ERM with its driver transistor on the module.
// SIG high = motor on. Patterns are timed in this task; nothing else touches the pin.
#include "haptic.h"
#include "board.h"
#include "dt_port.h"
#include "dt_protocol.h"
#include <Arduino.h>

extern QueueHandle_t haptic_q;

#define SETTLE_MS 120   // ring-down after the motor stops before trusting the IMU again

static volatile uint32_t blank_start_us, blank_end_us;

void haptic_init(void)
{
    pinMode(BOARD_MOTOR_PIN, OUTPUT);
    digitalWrite(BOARD_MOTOR_PIN, LOW);
}

bool haptic_blanked(uint32_t t_us)
{
    uint32_t s = blank_start_us, e = blank_end_us;
    return (int32_t)(t_us - s) >= 0 && (int32_t)(e - t_us) >= 0;
}

static void pulse(uint32_t on_ms)
{
    digitalWrite(BOARD_MOTOR_PIN, HIGH);
    vTaskDelay(pdMS_TO_TICKS(on_ms));
    digitalWrite(BOARD_MOTOR_PIN, LOW);
}

static void play(uint8_t pattern)
{
    uint32_t total_ms;
    switch (pattern) {
    case DT_HAPTIC_SHORT:  total_ms = 80;  break;
    case DT_HAPTIC_DOUBLE: total_ms = 200; break;
    case DT_HAPTIC_LONG:   total_ms = 400; break;
    default: return;
    }
    blank_start_us = dt_now_us();
    blank_end_us = blank_start_us + (total_ms + SETTLE_MS) * 1000;
    switch (pattern) {
    case DT_HAPTIC_SHORT:  pulse(80); break;
    case DT_HAPTIC_DOUBLE: pulse(70); vTaskDelay(pdMS_TO_TICKS(60)); pulse(70); break;
    case DT_HAPTIC_LONG:   pulse(400); break;
    }
}

void haptic_task(void *arg)
{
    uint8_t p;
    for (;;) {
        if (xQueueReceive(haptic_q, &p, portMAX_DELAY) == pdTRUE) play(p);
    }
}
