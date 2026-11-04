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

// Slide-forward gesture detection (phase 2 of calibration). Velocity is the
// leaky integral of world-frame horizontal acceleration (time constant
// FWD_LEAK_S), so bias does not accumulate while waiting; a slide, even a slow
// one, builds speed past FWD_ONSET_SPEED. From onset, integrate without leak
// for FWD_INTEGRATE_MS and take the direction at peak speed.
#define FWD_WAIT_MS       8000   // how long we wait for the foot to start moving
#define FWD_SETTLE_MS      300   // ignore motion right after the cue buzz
#define FWD_LEAK_S         0.5f  // leak time constant while waiting
#define FWD_ONSET_SPEED   0.008f // g·s (≈0.08 m/s) counts as "moving"
#define FWD_INTEGRATE_MS   800   // integrate velocity this long after onset
#define FWD_MIN_SPEED     0.012f // g·s (≈0.12 m/s): slower than this is not a slide

// Stillness: gyro quiet and acceleration not wandering from where the run began.
#define STILL_GYRO_DPS     8.0f  // includes the uncorrected gyro bias in phase 1
#define STILL_ACC_G        0.05f
#define CAL_STILL_MS       1500  // phase 1 starts by itself after this long still
#define CAL_STILL_WAIT_MS 12000

// Phase 2: several slides, which must agree.
#define CAL_SLIDES         3
#define CAL_MAX_SPREAD_DEG 15.0f // any slide this far from the mean: redo
#define RETURN_END_MS       200  // the slide has ended once still this long
#define RETURN_WAIT_MS     4000  // how long to wait for the foot to start coming back
#define RETURN_STILL_MS     700
#define RETURN_STILL_WAIT_MS 6000
#define RETURN_MOVE_DPS    25.0f
#define RETURN_MOVE_G       0.1f

// Moved-strap check: outside calibration, a second of stillness should show
// gravity near +z of the calibrated frame. Hysteresis so it does not flicker.
#define MOVED_STILL_MS     1000
#define MOVED_GYRO_DPS      5.0f
#define MOVED_ACC_G         0.03f
#define MOVED_SET_DEG      20.0f
#define MOVED_CLEAR_DEG    12.0f

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
static volatile bool calibrating;   // from the request until a result is in cal_phase
static volatile bool cal_request, cal_cancel;
static volatile uint8_t cal_phase;  // dt_cal_phase_t
static volatile uint8_t cal_slides; // slides seen so far in this run
static volatile uint8_t cal_spread; // degrees, last run
static volatile bool moved;         // gravity no longer matches the calibration

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

// Runs on every sample, in the calibrated frame with gyro bias removed.
static void moved_check(const float a[3], const float g[3], uint32_t t_us)
{
    static float ref[3], sum[3];
    static uint32_t run_start;
    static bool in_run;
    if (calibrating || !cal.valid) { in_run = false; return; }
    float gm = sqrtf(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    float d[3] = {a[0] - ref[0], a[1] - ref[1], a[2] - ref[2]};
    float dev = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if (!in_run || gm > MOVED_GYRO_DPS || dev > MOVED_ACC_G) {
        memcpy(ref, a, sizeof ref);
        memset(sum, 0, sizeof sum);
        run_start = t_us;
        in_run = true;
    }
    for (int i = 0; i < 3; i++) sum[i] += a[i];
    if (t_us - run_start < MOVED_STILL_MS * 1000u) return;
    float n = sqrtf(sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]);
    float tilt = n > 0 ? acosf(fminf(1.0f, fmaxf(-1.0f, sum[2] / n))) / DEG2RAD : 0;
    if (tilt > MOVED_SET_DEG) moved = true;
    else if (tilt < MOVED_CLEAR_DEG) moved = false;
    in_run = false;
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
        moved_check(a, g, s.t_us);

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

static float norm3(const float v[3])
{
    return sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

// Waits until the board has been still for hold_ms. On success the means of the
// still run go to a_out and g_out (either may be NULL). False on timeout or cancel.
static bool wait_still(uint32_t hold_ms, uint32_t timeout_ms, float *a_out, float *g_out)
{
    uint32_t next = count, run_start = 0;
    TickType_t t_start = xTaskGetTickCount();
    float ref[3] = {0}, a[3] = {0}, g[3] = {0};
    float last_gm = 0, last_dev = 0;
    int n = 0;
    fused_sample_t f;
    while (!cal_cancel && xTaskGetTickCount() - t_start <= pdMS_TO_TICKS(timeout_ms)) {
        while (next < count) {
            if (!fusion_get(next, &f)) { next = count; n = 0; break; }
            next++;
            float fa[3] = {f.raw.ax, f.raw.ay, f.raw.az}, fg[3] = {f.raw.gx, f.raw.gy, f.raw.gz};
            float d[3] = {fa[0] - ref[0], fa[1] - ref[1], fa[2] - ref[2]};
            float gm = norm3(fg), dev = norm3(d);
            if (n == 0 || gm > STILL_GYRO_DPS || dev > STILL_ACC_G) {
                if (n) { last_gm = gm; last_dev = dev; }
                memcpy(ref, fa, sizeof ref);
                memset(a, 0, sizeof a);
                memset(g, 0, sizeof g);
                n = 0;
                run_start = f.t_us;
            }
            for (int i = 0; i < 3; i++) { a[i] += fa[i]; g[i] += fg[i]; }
            n++;
            if (f.t_us - run_start >= hold_ms * 1000u) {
                for (int i = 0; i < 3; i++) {
                    if (a_out) a_out[i] = a[i] / n;
                    if (g_out) g_out[i] = g[i] / n;
                }
                return true;
            }
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!cal_cancel) DT_LOGW(TAG, "not still within %lu ms (last motion: gyro %.1f dps, accel %.3f g)",
                             (unsigned long)timeout_ms, last_gm, last_dev);
    return false;
}

// Phase 1: wait for real stillness, then gravity alignment and gyro bias.
static bool calibrate_still(void)
{
    float a[3], g[3];
    if (!wait_still(CAL_STILL_MS, CAL_STILL_WAIT_MS, a, g)) return false;
    float an = norm3(a);
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

// Phase 2, one slide. The velocity direction at peak speed, in the world frame,
// is the toe direction; its angle from the sensor x axis (also in the world
// frame) goes to *yaw_out. False if no slide was seen.
static bool detect_slide(float *yaw_out)
{
    uint32_t next = count;
    TickType_t t_start = xTaskGetTickCount();
    bool moving = false;
    float v[2] = {0, 0}, v_best = 0, v_dir[2] = {1, 0}, x_dir[2] = {1, 0};
    float a_max = 0, v_wait_max = 0;
    uint32_t onset_t_us = 0, last_t_us = 0;
    fused_sample_t f;

    for (;;) {
        if (cal_cancel) return false;
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
            float dt = last_t_us ? (f.t_us - last_t_us) * 1e-6f : 0.01f;
            last_t_us = f.t_us;
            float ah = sqrtf(a_w[0] * a_w[0] + a_w[1] * a_w[1]);
            if (ah > a_max) a_max = ah;

            if (!moving) {
                if (el <= pdMS_TO_TICKS(FWD_SETTLE_MS)) continue;
                float leak = 1.0f - dt / FWD_LEAK_S;
                v[0] = v[0] * leak + a_w[0] * dt;
                v[1] = v[1] * leak + a_w[1] * dt;
                float sp = sqrtf(v[0] * v[0] + v[1] * v[1]);
                if (sp > v_wait_max) v_wait_max = sp;
                if (sp > FWD_ONSET_SPEED) {
                    moving = true;
                    onset_t_us = f.t_us;
                    v_best = sp; v_dir[0] = v[0]; v_dir[1] = v[1]; x_dir[0] = xw[0]; x_dir[1] = xw[1];
                }
                continue;
            }
            v[0] += a_w[0] * dt; v[1] += a_w[1] * dt;   // g·s, no leak during the slide
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
    if (!moving) {
        DT_LOGW(TAG, "no slide seen in %d s (peak |a| %.2f g, peak speed %.3f g·s)",
                FWD_WAIT_MS / 1000, a_max, v_wait_max);
        return false;
    }
    if (v_best < FWD_MIN_SPEED) { DT_LOGW(TAG, "slide too slow (%.3f g·s)", v_best); return false; }

    *yaw_out = atan2f(v_dir[1], v_dir[0]) - atan2f(x_dir[1], x_dir[0]);
    DT_LOGI(TAG, "slide: toe is %.0f° from sensor x, peak %.3f g·s", *yaw_out / DEG2RAD, v_best);
    return true;
}

// Between slides: the slide ends, the foot comes back, the foot settles. A foot
// that never comes back just moves on after RETURN_WAIT_MS.
static void wait_return(void)
{
    wait_still(RETURN_END_MS, RETURN_WAIT_MS, NULL, NULL);
    uint32_t next = count;
    TickType_t t_start = xTaskGetTickCount();
    fused_sample_t f;
    bool came_back = false;
    while (!came_back && !cal_cancel && xTaskGetTickCount() - t_start <= pdMS_TO_TICKS(RETURN_WAIT_MS)) {
        while (next < count) {
            if (!fusion_get(next, &f)) { next = count; break; }
            next++;
            float a[3] = {f.raw.ax, f.raw.ay, f.raw.az}, g[3] = {f.raw.gx, f.raw.gy, f.raw.gz};
            if (norm3(g) > RETURN_MOVE_DPS || fabsf(norm3(a) - 1.0f) > RETURN_MOVE_G) came_back = true;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (came_back) wait_still(RETURN_STILL_MS, RETURN_STILL_WAIT_MS, NULL, NULL);
}

static void cal_run(void)
{
    DT_LOGI(TAG, "calibrating: waiting for %d ms of stillness", CAL_STILL_MS);
    cal_slides = 0;
    cal_spread = 0;
    moved = false;

    // Phase 1 reads *unaligned* raw samples: temporarily identity-align.
    calibration_t prev = cal;
    memset(&cal, 0, sizeof cal);
    cal.q_align[0] = 1.0f;
    cal_compose();

    if (!calibrate_still()) {
        DT_LOGW(TAG, "keeping previous calibration");
        cal = prev;
        cal_compose();
        if (cal_cancel) { cal_phase = DT_CAL_IDLE; return; }
        cue(DT_HAPTIC_LONG);
        cal_phase = DT_CAL_FAIL_STILL;
        return;
    }

    float yaws[CAL_SLIDES];
    bool ok = true;
    for (int i = 0; i < CAL_SLIDES && ok && !cal_cancel; i++) {
        cal_phase = DT_CAL_SLIDE;
        cue(DT_HAPTIC_SHORT);             // "now slide"
        DT_LOGI(TAG, "now slide this foot forward (%d of %d)", i + 1, CAL_SLIDES);
        ok = detect_slide(&yaws[i]);
        if (ok) {
            cal_slides = i + 1;
            if (i + 1 < CAL_SLIDES) {
                cal_phase = DT_CAL_RETURN;
                wait_return();
            }
        }
    }
    if (cal_cancel) {
        DT_LOGI(TAG, "cancelled; keeping previous calibration");
        cal = prev;
        cal_compose();
        madgwick_init(&ahrs, 0.1f);
        cal_phase = DT_CAL_IDLE;
        return;
    }

    // A failed gesture is reported as exactly that: tilt only, no toe direction.
    // The old direction is never kept, since the strap may have moved since.
    uint8_t result = DT_CAL_DONE;
    if (!ok) {
        result = DT_CAL_FAIL_SLIDE;
    } else {
        float sc = 0, cc = 0;
        for (int i = 0; i < CAL_SLIDES; i++) { sc += sinf(yaws[i]); cc += cosf(yaws[i]); }
        float mean = atan2f(sc, cc), spread = 0;
        for (int i = 0; i < CAL_SLIDES; i++) {
            float d = yaws[i] - mean;
            d = fabsf(atan2f(sinf(d), cosf(d))) / DEG2RAD;
            if (d > spread) spread = d;
        }
        cal_spread = (uint8_t)fminf(spread + 0.5f, 180.0f);
        if (spread > CAL_MAX_SPREAD_DEG) {
            DT_LOGW(TAG, "slides disagree: up to %.0f° from their mean", spread);
            result = DT_CAL_FAIL_SPREAD;
        } else {
            cal.yaw_fwd = mean;
            cal.fwd_valid = 1;
            cal_compose();
            madgwick_init(&ahrs, 0.1f);
            DT_LOGI(TAG, "forward ok: toe is %.0f° from sensor x, slides within %.0f°", mean / DEG2RAD, spread);
        }
    }
    cal_save();
    cue(result == DT_CAL_DONE ? DT_HAPTIC_DOUBLE : DT_HAPTIC_LONG);
    cal_phase = result;
}

void fusion_cal_task(void *arg)
{
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(50));
        if (!cal_request) continue;
        cal_request = false;
        cal_run();
        calibrating = false;
    }
}

void fusion_calibrate(void)
{
    if (calibrating) return;
    cal_cancel = false;
    cal_phase = DT_CAL_STILL;
    calibrating = true;
    cal_request = true;
}

void fusion_calibrate_cancel(void)
{
    if (calibrating) cal_cancel = true;
}

uint8_t fusion_cal_phase(void)  { return cal_phase; }
uint8_t fusion_cal_slides(void) { return cal_slides; }
uint8_t fusion_cal_spread(void) { return cal_spread; }
bool fusion_board_moved(void)   { return moved; }
