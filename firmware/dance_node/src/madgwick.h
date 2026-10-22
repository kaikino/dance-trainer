#pragma once
// Madgwick AHRS, 6-axis (IMU) variant. Public domain reference implementation,
// adapted to a struct so each node instance carries its own state.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float beta;             // algorithm gain; 0.1 is a good start for 100 Hz
    float q0, q1, q2, q3;   // quaternion of sensor frame relative to earth frame
} madgwick_t;

void madgwick_init(madgwick_t *m, float beta);
// gx,gy,gz in rad/s; ax,ay,az in any unit (normalized inside); dt in seconds.
void madgwick_update_imu(madgwick_t *m, float gx, float gy, float gz,
                         float ax, float ay, float az, float dt);

#ifdef __cplusplus
}
#endif
