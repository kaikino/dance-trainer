#include "fusion.h"
#include "madgwick.h"
#include <math.h>
#include <string.h>
#include "dt_port.h"
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

static const char *TAG = "fusion";
extern QueueHandle_t sample_q;

#define CAL_NAME "cal1"
#define DEG2RAD  0.017453292519943f

typedef struct {
    float gyro_bias[3];      // dps
    float q_align[4];        // w x y z: raw sensor → aligned sensor (gravity → +z)
    uint8_t valid;
} calibration_t;

static madgwick_t ahrs;
static fused_sample_t ring[FUSION_RING_LEN];
static volatile uint32_t count;
static calibration_t cal;
static bool mirror_y;            // left foot: flip y so +y = outward on both feet
static bool calibrating;         // calibration reads raw samples through the ring

// ---- quaternion helpers (w, x, y, z) ----------------------------------------

static void q_rotate(const float q[4], const float v[3], float out[3])
{
    float w = q[0], x = q[1], y = q[2], z = q[3];
    out[0] = (1 - 2 * (y * y + z * z)) * v[0] + 2 * (x * y - w * z) * v[1] + 2 * (x * z + w * y) * v[2];
    out[1] = 2 * (x * y + w * z) * v[0] + (1 - 2 * (x * x + z * z)) * v[1] + 2 * (y * z - w * x) * v[2];
    out[2] = 2 * (x * z - w * y) * v[0] + 2 * (y * z + w * x) * v[1] + (1 - 2 * (x * x + y * y)) * v[2];
}

// Shortest rotation taking unit vector a onto unit vector b.
static void q_from_to(const float a[3], const float b[3], float q[4])
{
    float d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    float c[3] = {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
    q[0] = 1.0f + d; q[1] = c[0]; q[2] = c[1]; q[3] = c[2];
    if (q[0] < 1e-6f) { q[0] = 0; q[1] = 1; q[2] = 0; q[3] = 0; }  // 180°: pick x axis
    float n = sqrtf(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    for (int i = 0; i < 4; i++) q[i] /= n;
}

// ---- calibration persistence ------------------------------------------------

static void cal_load(void)
{
    if (!storage_load(CAL_NAME, &cal, sizeof cal) || !cal.valid) {
        memset(&cal, 0, sizeof cal);
        cal.q_align[0] = 1.0f;
    }
    DT_LOGI(TAG, "calibration %s", cal.valid ? "loaded" : "absent");
}

static void cal_save(void)
{
    if (!storage_save(CAL_NAME, &cal, sizeof cal)) DT_LOGE(TAG, "calibration save failed");
}

bool fusion_is_calibrated(void) { return cal.valid; }

// ---- init / task --------------------------------------------------------------

void fusion_init(dt_role_t role)
{
    mirror_y = (role == DT_ROLE_LEFT);
    madgwick_init(&ahrs, 0.1f);
    cal_load();
}

void fusion_task(void *arg)
{
    imu_sample_t s;
    uint32_t last_t = 0;
    for (;;) {
        if (xQueueReceive(sample_q, &s, portMAX_DELAY) != pdTRUE) continue;
        float dt = last_t ? (s.t_us - last_t) * 1e-6f : 1.0f / IMU_RATE_HZ;
        last_t = s.t_us;

        // Align raw sensor axes so that gravity at the calibration pose is +z.
        float a_raw[3] = {s.ax, s.ay, s.az}, g_raw[3] = {s.gx, s.gy, s.gz};
        float a[3], g[3];
        q_rotate(cal.q_align, a_raw, a);
        q_rotate(cal.q_align, g_raw, g);
        for (int i = 0; i < 3; i++) g[i] -= cal.gyro_bias[i];

        madgwick_update_imu(&ahrs, g[0] * DEG2RAD, g[1] * DEG2RAD, g[2] * DEG2RAD, a[0], a[1], a[2], dt);

        // World-frame accel, gravity removed.
        float q[4] = {ahrs.q0, ahrs.q1, ahrs.q2, ahrs.q3};
        float a_w[3];
        q_rotate(q, a, a_w);
        a_w[2] -= 1.0f;

        // Remove yaw: rotate world x/y back by the foot's heading so +x = toe.
        // Heading = direction of the sensor x axis projected on the ground.
        float xs[3] = {1, 0, 0}, xw[3];
        q_rotate(q, xs, xw);
        float yaw = atan2f(xw[1], xw[0]);
        float c = cosf(yaw), sn = sinf(yaw);
        float ax_f =  c * a_w[0] + sn * a_w[1];
        float ay_f = -sn * a_w[0] + c * a_w[1];
        if (mirror_y) ay_f = -ay_f;

        fused_sample_t *f = &ring[count % FUSION_RING_LEN];
        f->t_us = s.t_us;
        f->qw = q[0]; f->qx = q[1]; f->qy = q[2]; f->qz = q[3];
        f->ax_f = ax_f; f->ay_f = ay_f; f->az_f = a_w[2];
        f->raw = s;
        f->raw.ax = a[0]; f->raw.ay = a[1]; f->raw.az = a[2];
        f->raw.gx = g[0]; f->raw.gy = g[1]; f->raw.gz = g[2];
        count++;
    }
}

bool fusion_get(uint32_t idx, fused_sample_t *out)
{
    uint32_t c = count;
    if (idx >= c || c - idx > FUSION_RING_LEN) return false;
    *out = ring[idx % FUSION_RING_LEN];
    return true;
}

uint32_t fusion_count(void) { return count; }

// ---- calibration ------------------------------------------------------------

void fusion_calibrate(void)
{
    if (calibrating) return;
    calibrating = true;
    DT_LOGI(TAG, "calibrating: hold still for 2 s");

    // Collect against the *unaligned* raw samples: temporarily identity-align.
    calibration_t prev = cal;
    memset(&cal, 0, sizeof cal);
    cal.q_align[0] = 1.0f;

    uint32_t start = count;
    vTaskDelay(pdMS_TO_TICKS(2000));
    uint32_t end = count;

    float a[3] = {0}, g[3] = {0};
    int n = 0;
    fused_sample_t f;
    for (uint32_t i = start; i < end; i++) {
        if (!fusion_get(i, &f)) continue;
        a[0] += f.raw.ax; a[1] += f.raw.ay; a[2] += f.raw.az;
        g[0] += f.raw.gx; g[1] += f.raw.gy; g[2] += f.raw.gz;
        n++;
    }
    if (n < 100) {
        DT_LOGW(TAG, "too few samples (%d), keeping previous calibration", n);
        cal = prev;
        calibrating = false;
        return;
    }
    for (int i = 0; i < 3; i++) { a[i] /= n; g[i] /= n; }
    float an = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    if (fabsf(an - 1.0f) > 0.15f) {
        DT_LOGW(TAG, "|a| = %.2f g during calibration, not still; keeping previous", an);
        cal = prev;
        calibrating = false;
        return;
    }

    float up[3] = {0, 0, 1}, a_unit[3] = {a[0] / an, a[1] / an, a[2] / an};
    q_from_to(a_unit, up, cal.q_align);
    // Gyro bias is measured in raw axes; store it in the aligned frame.
    q_rotate(cal.q_align, g, cal.gyro_bias);
    cal.valid = 1;
    cal_save();
    madgwick_init(&ahrs, 0.1f);   // restart near identity in the aligned frame

    DT_LOGI(TAG, "calibrated: tilt %.1f°, gyro bias %.2f %.2f %.2f dps",
             acosf(fminf(1.0f, a_unit[2])) / DEG2RAD, cal.gyro_bias[0], cal.gyro_bias[1], cal.gyro_bias[2]);
    calibrating = false;
}
