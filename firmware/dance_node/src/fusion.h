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

// Runs in its own task; these calls return at once and fusion_cal_phase() follows
// progress. (1) Waits for 1.5 s of real stillness → gravity alignment and gyro
// bias. (2) Three slides forward, foot brought back between them; they must agree
// within 15°. Short buzz = slide now, double buzz = done, long buzz = failed. A
// failed slide leaves the node tilt-only rather than keeping an old direction.
// Stored in flash, so a node keeps its calibration across power cycles.
void fusion_cal_task(void *arg);
void fusion_calibrate(void);
void fusion_calibrate_cancel(void);           // restores the previous calibration
uint8_t fusion_cal_phase(void);               // dt_cal_phase_t
uint8_t fusion_cal_slides(void);              // slides seen in this run
uint8_t fusion_cal_spread(void);              // degrees: worst slide from their mean
bool fusion_board_moved(void);                // still, but gravity is far from calibrated "up"
bool fusion_is_calibrated(void);              // still pose done
bool fusion_has_forward(void);                // slides done and agreeing too

#ifdef __cplusplus
}
#endif
