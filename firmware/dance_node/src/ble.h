#pragma once
#include "dt_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

// Starts the SoftDevice, registers the Dance Trainer service, advertises as
// DT-L / DT-R, and spawns the status, event and stream notify tasks.
void ble_init(dt_role_t role);
bool ble_connected(void);

#ifdef __cplusplus
}
#endif
