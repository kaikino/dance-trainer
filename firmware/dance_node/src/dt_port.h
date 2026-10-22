#pragma once
// The few platform services the portable C modules need. Implemented in port.cpp
// on the Arduino/Adafruit nRF52 core. Everything else talks FreeRTOS directly.
#include <stdint.h>
#include <stdbool.h>
#include "dt_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

void     port_init(void);
uint32_t dt_now_us(void);          // free-running µs counter (TIMER4), wraps at 71 min
dt_role_t dt_role(void);           // stored role, else compile-time default
void     dt_log(char level, const char *tag, const char *fmt, ...);

#define DT_LOGI(tag, ...) dt_log('I', tag, __VA_ARGS__)
#define DT_LOGW(tag, ...) dt_log('W', tag, __VA_ARGS__)
#define DT_LOGE(tag, ...) dt_log('E', tag, __VA_ARGS__)

// Blob storage on the internal LittleFS. Returns false if absent or wrong size.
bool storage_load(const char *name, void *buf, uint32_t len);
bool storage_save(const char *name, const void *buf, uint32_t len);

#ifdef __cplusplus
}
#endif
