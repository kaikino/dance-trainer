#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// One raw IMU sample, sensor frame. Produced at ~104 Hz by imu_task.
typedef struct {
    uint32_t t_us;       // dt_now_us() at data-ready
    float ax, ay, az;    // g
    float gx, gy, gz;    // dps
} imu_sample_t;

#define IMU_RATE_HZ 100

bool imu_init(void);        // powers the LSM6DS3TR-C, configures 104 Hz, ±16 g, ±2000 dps, INT1 DRDY
void imu_task(void *arg);   // waits on INT1, reads a sample, pushes to sample_q

#ifdef __cplusplus
}
#endif
