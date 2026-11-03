#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "imu.h"
#include "dt_protocol.h"

// One fused sample.
//
// Frames:
//   sensor  = IMU axes after the calibration rotation: +z = up at the still pose,
//             +x = the toe direction measured during the slide-forward gesture.
//             Mount-independent (tilt and strap rotation both cancelled).
//   foot    = sensor frame leveled by the orientation filter (roll/pitch removed),
//             heading removed so +x = toe at every instant, gravity removed, and
//             y mirrored on the RIGHT node so +y = outward on both feet.
//   The classifier window carries both (ml/dt/windows.py rebuilds the same).
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t t_us;
    float qw, qx, qy, qz;      // sensor → world (Madgwick), streamed to the app
    float ax_f, ay_f, az_f;    // g, foot frame, gravity removed (y mirrored on the right node)
    imu_sample_t raw;          // sensor frame as defined above, NOT mirrored
} fused_sample_t;

// Ring buffer shared with stepdet and the BLE stream. 2 s at 100 Hz.
#define FUSION_RING_LEN 200

void fusion_init(dt_role_t role);             // loads calibration from flash if present
void fusion_task(void *arg);                  // sample_q → ring
bool fusion_get(uint32_t idx, fused_sample_t *out);  // idx = absolute sample count
uint32_t fusion_count(void);                  // samples written so far

// Two phases, blocking, up to ~8 s: (1) 2 s still pose → gravity alignment and
// gyro bias, then a short buzz; (2) the dancer slides this foot forward once →
// toe direction. Double buzz = both done, long buzz = still pose only. Stored
// in flash, so a node keeps its calibration across power cycles.
void fusion_calibrate(void);
bool fusion_is_calibrated(void);              // still pose done
bool fusion_has_forward(void);                // slide-forward gesture done too

#ifdef __cplusplus
}
#endif
