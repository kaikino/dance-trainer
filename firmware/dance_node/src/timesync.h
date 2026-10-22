#pragma once
#include <stdint.h>
#include "dt_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

void timesync_init(void);
// Build the reply for a Time sync write. Called from the BLE write callback;
// the reply is notified back immediately by the BLE layer.
void timesync_reply(uint32_t t_app_ms, dt_timesync_reply_t *out);

#ifdef __cplusplus
}
#endif
