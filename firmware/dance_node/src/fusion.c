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
extern QueueHandle_t haptic_q;   // cue the dancer between calibration phases

#define CAL_NAME "cal2"
#define DEG2RAD  0.017453292519943f

// Slide-forward gesture detection (phase 2 of calibration).
#define FWD_WAIT_MS       5000   // how long we wait for the foot to start moving
#define FWD_SETTLE_MS      300   // ignore motion right after the cue buzz
#define FWD_ONSET_G       0.35f  // horizontal |a_world| that counts as "moving"
#define FWD_INTEGRATE_MS   700   // integrate velocity this long after onset
#define FWD_MIN_SPEED     0.015f // g·s (≈0.15 m/s): slower than this is not a slide

typedef struct {
    float gyro_bias[3];      // dps, in the leveled frame
    float q_align[4];        // w x y z: raw sensor → leveled sensor (gravity → +z)
    float yaw_fwd;           // rad: angle from the leveled sensor x axis to the toe direction
    uint8_t valid;           // still pose done
    uint8_t fwd_valid;       // slide-forward gesture done (else yaw_fwd = 0: trust the mounting)
} calibration_t;

static madgwick_t ahrs;
static fused_sample_t ring[FUSION_RING_LEN];
static volatile uint32_t count;
static calibration_t cal;
static float q_total[4];         // raw sensor → foot-aligned sensor: q_align, then -yaw_fwd about z
static bool mirror_y;            // right foot: flip y so +y = outward on both feet
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

// q = a ⊗ b: apply b first, then a.
static void q_mul(const float a[4], const float b[4], float q[4])
{
    q[0] = a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3];
    q[1] = a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2];
    q[2] = a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1];
    q[3] = a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0];
}

// Rotation of -yaw_fwd about z after q_align, so +x of the result is the toe.
static void cal_compose(void)
{
    float h = -0.5f * cal.yaw_fwd;
    float qz[4] = {cosf(h), 0, 0, sinf(h)};
    q_mul(qz, cal.q_align, q_total);
}

// ---- calibration persistence ------------------------------------------------

static void cal_load(void)
{
    if (!storage_load(CAL_NAME, &cal, sizeof cal) || !cal.valid) {
        memset(&cal, 0, sizeof cal);
        cal.q_align[0] = 1.0f;
    }
    cal_compose();
    DT_LOGI(TAG, "calibration %s%s", cal.valid ? "loaded" : "absent",
            cal.valid && !cal.fwd_valid ? " (no forward gesture: trusting the mounting)" : "");
}

static void cal_save(void)
{
    if (!storage_save(CAL_NAME, &cal, sizeof cal)) DT_LOGE(TAG, "calibration save failed");
}

bool fusion_is_calibrated(void) { return cal.valid; }
bool fusion_has_forward(void)   { return cal.valid && cal.fwd_valid; }

// ---- init / task --------------------------------------------------------------

void fusion_init(dt_role_t role)
{
    // Calibrated frame: +x toe, +z up, hence +y = the dancer's LEFT. Outward on the
    // right foot is -y, so the right node is mirrored to make +y = outward on both.
    mirror_y = (role == DT_ROLE_RIGHT);
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

        // Raw sensor axes → foot-aligned sensor frame: gravity at the still pose is
        // +z, the slide-forward direction is +x. Everything downstream, including
        // the raw channels of the classifier window, is therefore independent of
        // how the board happens to sit on the strap.
        float a_raw[3] = {s.ax, s.ay, s.az}, g_raw[3] = {s.gx, s.gy, s.gz};
        float a[3], g[3];
        q_rotate(q_total, a_raw, a);
        q_rotate(q_total, g_raw, g);
        for (int i = 0; i < 3; i++) g[i] -= cal.gyro_bias[i];

        madgwick_update_imu(&ahrs, g[0] * DEG2RAD, g[1] * DEG2RAD, g[2] * DEG2RAD, a[0], a[1], a[2], dt);

        // World-frame accel, gravity removed.
        float q[4] = {ahrs.q0, ahrs.q1, ahrs.q2, ahrs.q3};
        float a_w[3];
        q_rotate(q, a, a_w);
        a_w[2] -= 1.0f;

        // Remove heading: rotate world x/y back by the direction the toe points.
        float xs[3] = {1, 0, 0}, xw[3];
        q_rotate(q, xs, xw);
        float yaw = atan2f(xw[1], xw[0]);
        float c = cosf(yaw), sn = sinf(yaw);
        float ax_f =  c * a_w[0] + sn * a_w[1];
        float ay_f = -sn * a_w[0] + c * a_w[1];
        if (mirror_y) ay_f = -ay_f;   // raw channels are mirrored later, in stepdet.c

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

static void cue(uint8_t pattern)
{
    if (haptic_q) xQueueSend(haptic_q, &pattern, 0);
}

// Phase 1: 2 s still pose → gravity alignment and gyro bias. Returns false if not still.
static bool calibrate_still(void)
{
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
    if (n < 100) { DT_LOGW(TAG, "too few samples (%d)", n); return false; }
    for (int i = 0; i < 3; i++) { a[i] /= n; g[i] /= n; }
    float an = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    if (fabsf(an - 1.0f) > 0.15f) { DT_LOGW(TAG, "|a| = %.2f g, not still", an); return false; }

    float up[3] = {0, 0, 1}, a_unit[3] = {a[0] / an, a[1] / an, a[2] / an};
    q_from_to(a_unit, up, cal.q_align);
    q_rotate(cal.q_align, g, cal.gyro_bias);   // bias measured raw, stored leveled
    cal.yaw_fwd = 0; cal.fwd_valid = 0;
    cal.valid = 1;
    cal_compose();
    madgwick_init(&ahrs, 0.1f);   // restart at identity in the leveled frame
    DT_LOGI(TAG, "still pose ok: tilt %.1f°, gyro bias %.2f %.2f %.2f dps",
            acosf(fminf(1.0f, a_unit[2])) / DEG2RAD, cal.gyro_bias[0], cal.gyro_bias[1], cal.gyro_bias[2]);
    return true;
}

// Phase 2: the dancer slides the foot forward once. The velocity direction at peak
// speed, in the world frame, is the toe direction; its angle from the sensor x
// axis (also in the world frame) is yaw_fwd. Returns false if no slide was seen.
static bool calibrate_forward(void)
{
    DT_LOGI(TAG, "now slide this foot forward once");
    uint32_t next = count;
    TickType_t t_start = xTaskGetTickCount();
    bool moving = false;
    float v[2] = {0, 0}, v_best = 0, v_dir[2] = {1, 0}, x_dir[2] = {1, 0};
    uint32_t onset_t_us = 0, last_t_us = 0;
    fused_sample_t f;

    for (;;) {
        TickType_t el = xTaskGetTickCount() - t_start;
        if (!moving && el > pdMS_TO_TICKS(FWD_WAIT_MS)) break;
        while (next < count) {
            if (!fusion_get(next, &f)) { next = count; break; }
            next++;
            // World-frame horizontal acceleration and sensor-x heading, from the ring.
            float q[4] = {f.qw, f.qx, f.qy, f.qz};
            float a[3] = {f.raw.ax, f.raw.ay, f.raw.az}, a_w[3];
            q_rotate(q, a, a_w);
            float xs[3] = {1, 0, 0}, xw[3];
            q_rotate(q, xs, xw);
            float ah = sqrtf(a_w[0] * a_w[0] + a_w[1] * a_w[1]);

            if (!moving) {
                if (el > pdMS_TO_TICKS(FWD_SETTLE_MS) && ah > FWD_ONSET_G) {
                    moving = true;
                    onset_t_us = last_t_us = f.t_us;
                    v[0] = v[1] = 0;
                }
                continue;
            }
            float dt = (f.t_us - last_t_us) * 1e-6f;
            last_t_us = f.t_us;
            v[0] += a_w[0] * dt; v[1] += a_w[1] * dt;   // g·s
            float sp = sqrtf(v[0] * v[0] + v[1] * v[1]);
            if (sp > v_best) {
                v_best = sp;
                v_dir[0] = v[0]; v_dir[1] = v[1];
                x_dir[0] = xw[0]; x_dir[1] = xw[1];
            }
            if (f.t_us - onset_t_us > FWD_INTEGRATE_MS * 1000u) goto done;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
done:
    if (!moving) { DT_LOGW(TAG, "no slide seen in %d s", FWD_WAIT_MS / 1000); return false; }
    if (v_best < FWD_MIN_SPEED) { DT_LOGW(TAG, "slide too slow (%.3f g·s)", v_best); return false; }

    cal.yaw_fwd = atan2f(v_dir[1], v_dir[0]) - atan2f(x_dir[1], x_dir[0]);
    cal.fwd_valid = 1;
    cal_compose();
    madgwick_init(&ahrs, 0.1f);
    DT_LOGI(TAG, "forward ok: toe is %.0f° from sensor x, peak %.2f g·s", cal.yaw_fwd / DEG2RAD, v_best);
    return true;
}

void fusion_calibrate(void)
{
    if (calibrating) return;
    calibrating = true;
    DT_LOGI(TAG, "calibrating: hold still for 2 s");

    // Phase 1 reads *unaligned* raw samples: temporarily identity-align.
    calibration_t prev = cal;
    memset(&cal, 0, sizeof cal);
    cal.q_align[0] = 1.0f;
    cal_compose();

    if (!calibrate_still()) {
        DT_LOGW(TAG, "keeping previous calibration");
        cal = prev;
        cal_compose();
        calibrating = false;
        return;
    }
    cue(DT_HAPTIC_SHORT);                 // "now slide"
    if (!calibrate_forward()) {
        if (prev.valid && prev.fwd_valid) {
            // Keep the old forward direction; the mounting has not changed much.
            cal.yaw_fwd = prev.yaw_fwd; cal.fwd_valid = 1;
            cal_compose();
            DT_LOGW(TAG, "reusing previous forward direction (%.0f°)", cal.yaw_fwd / DEG2RAD);
        } else {
            DT_LOGW(TAG, "no forward direction: trusting the mounting (USB toward the toe)");
        }
        cue(DT_HAPTIC_LONG);
    } else {
        cue(DT_HAPTIC_DOUBLE);
    }
    cal_save();
    calibrating = false;
}
