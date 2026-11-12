#include "stepdet.h"
#include "swingdet.h"
#include "fusion.h"
#include <math.h>
#include "haptic.h"
#include "dt_port.h"
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

static const char *TAG = "stepdet";
extern QueueHandle_t window_q;

// Per-channel int8 scales: value_int8 = clamp(value / scale * 127). Must equal
// ml/dt/windows.py SCALES (and MODEL_SCALES in model_weights.h). Sensor accel is
// 8 g, not the IMU's 16 g, so rules.c resolves the shank tilt to 3.6° per LSB.
static const float scales[WIN_CHANNELS] = {
    8.0f, 8.0f, 8.0f,           // sensor accel, g
    2000.0f, 2000.0f, 2000.0f,  // gyro, dps
    8.0f, 8.0f, 8.0f,           // world accel, g
};

static int8_t q8(float v, float scale)
{
    float x = v / scale * 127.0f;
    if (x > 127.0f) x = 127.0f;
    if (x < -128.0f) x = -128.0f;
    return (int8_t)lrintf(x);
}

static void cut_window(uint32_t strike_idx, step_window_t *w)
{
    // The right node mirrors y so +y = outward on both feet. The foot-frame
    // channels arrive mirrored from fusion; the sensor-frame ones are mirrored
    // here: accelerations flip y, rotation rates (axial vectors) flip x and z.
    // ml/dt/windows.py mirror_sensor() does the same.
    const float m = dt_role() == DT_ROLE_RIGHT ? -1.0f : 1.0f;
    fused_sample_t f;
    for (int i = 0; i < WIN_LEN; i++) {
        uint32_t idx = strike_idx - WIN_PRE_SAMPLES + i;
        if (!fusion_get(idx, &f)) {
            for (int c = 0; c < WIN_CHANNELS; c++) w->x[i][c] = 0;
            continue;
        }
        w->x[i][0] = q8(f.raw.ax, scales[0]);
        w->x[i][1] = q8(m * f.raw.ay, scales[1]);
        w->x[i][2] = q8(f.raw.az, scales[2]);
        w->x[i][3] = q8(m * f.raw.gx, scales[3]);
        w->x[i][4] = q8(f.raw.gy, scales[4]);
        w->x[i][5] = q8(m * f.raw.gz, scales[5]);
        w->x[i][6] = q8(f.ax_f, scales[6]);
        w->x[i][7] = q8(f.ay_f, scales[7]);
        w->x[i][8] = q8(f.az_f, scales[8]);
    }
}

// One strike per swing, at the landing, once the foot is planted (swingdet.c).
// The window is cut WIN_POST_SAMPLES after the strike, so the latency is
// ~200 ms after landing (more if the foot settles slowly).
void detect_task(void *arg)
{
    static swingdet_t det;
    swingdet_init(&det);
    uint32_t next = 0;          // next ring index to examine

    for (;;) {
        if (next >= fusion_count()) { vTaskDelay(pdMS_TO_TICKS(5)); continue; }
        fused_sample_t f;
        if (!fusion_get(next, &f)) {   // fell behind the ring: restart cleanly
            next = fusion_count();
            swingdet_init(&det);
            continue;
        }
        uint32_t idx = next++;
        float acc[3] = {f.raw.ax, f.raw.ay, f.raw.az};
        float gyr[3] = {f.raw.gx, f.raw.gy, f.raw.gz};
        float foot[3] = {f.ax_f, f.ay_f, f.az_f};
        // The motor on this ankle shakes the IMU; it may not start a swing.
        int32_t a = swingdet_feed(&det, idx, f.t_us, acc, gyr, foot, haptic_blanked(f.t_us), WIN_POST_SAMPLES);
        if (a < 0) continue;
        step_window_t w = { .t_strike_us = 0 };
        fused_sample_t p;
        if (fusion_get((uint32_t)a, &p)) w.t_strike_us = p.t_us;
        cut_window((uint32_t)a, &w);
        if (xQueueSend(window_q, &w, 0) != pdTRUE) DT_LOGW(TAG, "window_q full");
    }
}
