// Node bring-up and the serial console. The .ino only forwards setup()/loop() here.
#include <Arduino.h>
#include "board.h"
#include "dt_port.h"
#include "dt_protocol.h"
#include "imu.h"
#include "fusion.h"
#include "stepdet.h"
#include "model.h"
#include "judge.h"
#include "haptic.h"
#include "ble.h"
#include "timesync.h"
#include "power.h"

static const char *TAG = "main";

// Queues between tasks. A full queue means a consumer is stuck.
QueueHandle_t sample_q;   // imu_sample_t, 100 Hz
QueueHandle_t window_q;   // step_window_t, one per foot strike
QueueHandle_t haptic_q;   // uint8_t pattern
QueueHandle_t event_q;    // dt_step_event_t

void app_setup(void)
{
    port_init();
    delay(300);   // let USB CDC enumerate so the first log lines are visible
    dt_role_t role = dt_role();
    DT_LOGI(TAG, "dance node fw %d.%d role=%s classifier=%s", DT_FW_MAJOR, DT_FW_MINOR,
            role == DT_ROLE_LEFT ? "L" : "R", classifier_name());

    sample_q = xQueueCreate(32, sizeof(imu_sample_t));
    window_q = xQueueCreate(4, sizeof(step_window_t));
    haptic_q = xQueueCreate(8, sizeof(uint8_t));
    event_q  = xQueueCreate(16, sizeof(dt_step_event_t));

    bool have_imu = imu_init();
    if (!have_imu) DT_LOGE(TAG, "IMU not found; sensing disabled");
    haptic_init();
    power_init();
    fusion_init(role);
    judge_init();
    timesync_init();
    ble_init(role);

    // Stack sizes are in 32-bit words. Priorities: 4 highest; Bluefruit runs at 3.
    if (have_imu) xTaskCreate(imu_task, "imu", 512, NULL, TASK_PRIO_HIGHEST, NULL);
    xTaskCreate(fusion_task,      "fusion", 1024, NULL, TASK_PRIO_HIGH,   NULL);
    xTaskCreate(detect_task,      "detect", 1024, NULL, TASK_PRIO_NORMAL, NULL);
    xTaskCreate(infer_judge_task, "judge",  1536, NULL, TASK_PRIO_NORMAL, NULL);
    xTaskCreate(haptic_task,      "haptic", 256,  NULL, TASK_PRIO_NORMAL, NULL);
    DT_LOGI(TAG, "tasks started");
}

static void help(void)
{
    Serial.println("commands: status | cal | buzz [1|2|3] | selftest | role L|R | reboot | help");
}

static void handle(char *line)
{
    char *arg = strchr(line, ' ');
    if (arg) *arg++ = 0;
    if (!strcmp(line, "status")) {
        Serial.printf("role=%s mode=%d battery=%u mV (%u%%) ble=%s calibrated=%d t=%lu us\n",
                      dt_role() == DT_ROLE_LEFT ? "L" : "R", (int)judge_mode(), battery_mv(), battery_pct(),
                      ble_connected() ? "connected" : "advertising", (int)fusion_is_calibrated(),
                      (unsigned long)dt_now_us());
    } else if (!strcmp(line, "cal")) {
        fusion_calibrate();
    } else if (!strcmp(line, "buzz")) {
        uint8_t p = arg ? (uint8_t)atoi(arg) : DT_HAPTIC_LONG;
        xQueueSend(haptic_q, &p, 0);
    } else if (!strcmp(line, "selftest")) {
        model_selftest();
    } else if (!strcmp(line, "role") && arg && (arg[0] == 'L' || arg[0] == 'R')) {
        storage_save("role", arg, 1);
        Serial.printf("role %c stored; rebooting\n", arg[0]);
        delay(100);
        NVIC_SystemReset();
    } else if (!strcmp(line, "reboot")) {
        NVIC_SystemReset();
    } else {
        help();
    }
}

void app_loop(void)
{
    static char line[32];
    static size_t n;
    while (Serial.available()) {
        char c = (char)Serial.read();
        if (c == '\r') continue;
        if (c == '\n' || n == sizeof line - 1) {
            line[n] = 0;
            n = 0;
            if (line[0]) handle(line);
        } else {
            line[n++] = c;
        }
    }
    delay(20);
}
