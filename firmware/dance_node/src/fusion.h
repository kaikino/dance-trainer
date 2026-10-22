#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "imu.h"
#include "dt_protocol.h"

// One fused sample.
//
// Frames:
//   sensor  = IMU axes after the calibration alignment (z ≈ up when standing).
//   foot    = sensor frame leveled (roll/pitch removed) with yaw kept, then
//             mirrored on y for the left foot so +x = toe direction and
//             +y = outward for BOTH feet. Heading-independent. This is what
//             the classifier and ml/dt/windows.py use.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t t_us;
    float qw, qx, qy, qz;      // sensor → world (Madgwick), streamed to the app
    float ax_f, ay_f, az_f;    // g, foot frame, gravity removed
    imu_sample_t raw;          // aligned sensor frame (post-calibration rotation)
} fused_sample_t;

// Ring buffer shared with stepdet and the BLE stream. 2 s at 100 Hz.
#define FUSION_RING_LEN 200

void fusion_init(dt_role_t role);             // loads calibration from flash if present
void fusion_task(void *arg);                  // sample_q → ring
bool fusion_get(uint32_t idx, fused_sample_t *out);  // idx = absolute sample count
uint32_t fusion_count(void);                  // samples written so far

// 2 s still pose. Blocks. Stores gravity alignment + gyro bias in flash.
void fusion_calibrate(void);
bool fusion_is_calibrated(void);

#ifdef __cplusplus
}
#endif
