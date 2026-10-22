// Dance Trainer GATT service on Bluefruit (Nordic SoftDevice S140). See docs/ble-protocol.md.
#include "ble.h"
#include "board.h"
#include "dt_port.h"
#include "judge.h"
#include "fusion.h"
#include "timesync.h"
#include "model.h"
#include "power.h"
#include <Arduino.h>
#include <bluefruit.h>

static const char *TAG = "ble";
extern QueueHandle_t event_q, haptic_q;

static dt_role_t g_role;
static volatile uint16_t conn_hdl = BLE_CONN_HANDLE_INVALID;

// 128-bit UUIDs: 7d4eXXXX-5a1c-4b8e-9f3a-2c6d8e1f0a00, little-endian byte order.
#define DT_UUID128(x) { 0x00, 0x0a, 0x1f, 0x8e, 0x6d, 0x2c, 0x3a, 0x9f, 0x8e, 0x4b, 0x1c, 0x5a, \
                        (uint8_t)((x) & 0xff), (uint8_t)((x) >> 8), 0x4e, 0x7d }
static const uint8_t uuid_svc[16]      = DT_UUID128(DT_UUID_SERVICE);
static const uint8_t uuid_status[16]   = DT_UUID128(DT_UUID_STATUS);
static const uint8_t uuid_timesync[16] = DT_UUID128(DT_UUID_TIMESYNC);
static const uint8_t uuid_schedule[16] = DT_UUID128(DT_UUID_SCHEDULE);
static const uint8_t uuid_control[16]  = DT_UUID128(DT_UUID_CONTROL);
static const uint8_t uuid_event[16]    = DT_UUID128(DT_UUID_STEP_EVENT);
static const uint8_t uuid_stream[16]   = DT_UUID128(DT_UUID_STREAM);

static BLEService        svc(uuid_svc);
static BLECharacteristic chr_status(uuid_status);
static BLECharacteristic chr_timesync(uuid_timesync);
static BLECharacteristic chr_schedule(uuid_schedule);
static BLECharacteristic chr_control(uuid_control);
static BLECharacteristic chr_event(uuid_event);
static BLECharacteristic chr_stream(uuid_stream);

bool ble_connected(void) { return conn_hdl != BLE_CONN_HANDLE_INVALID; }

static void fill_status(dt_status_t *s)
{
    s->protocol_version = DT_PROTOCOL_VERSION;
    s->role = g_role;
    s->fw_version = (DT_FW_MAJOR << 8) | DT_FW_MINOR;
    s->battery_pct = battery_pct();
    s->mode = judge_mode();
}

static void push_status(void)
{
    dt_status_t s;
    fill_status(&s);
    chr_status.write(&s, sizeof s);
    if (ble_connected() && chr_status.notifyEnabled()) chr_status.notify(&s, sizeof s);
}

static void on_timesync(uint16_t, BLECharacteristic *, uint8_t *data, uint16_t len)
{
    if (len != 4) return;
    dt_timesync_reply_t r;
    uint32_t t_app_ms;
    memcpy(&t_app_ms, data, 4);
    timesync_reply(t_app_ms, &r);
    chr_timesync.notify(&r, sizeof r);
}

static void on_schedule(uint16_t, BLECharacteristic *, uint8_t *data, uint16_t len)
{
    if (len < 1) return;
    if (data[0] & DT_SCHED_FLAG_HEADER) {
        if (len < sizeof(dt_sched_header_t)) return;
        dt_sched_header_t h;
        memcpy(&h, data, sizeof h);
        judge_schedule_begin(&h);
    } else {
        int n = (len - 1) / sizeof(dt_sched_step_t);
        judge_schedule_add((const dt_sched_step_t *)(data + 1), n);
    }
}

static void on_control(uint16_t, BLECharacteristic *, uint8_t *data, uint16_t len)
{
    if (len < 1) return;
    switch (data[0]) {
    case DT_CMD_START: {
        if (len < 6) return;
        uint32_t t0; memcpy(&t0, data + 2, 4);
        judge_start((dt_mode_t)data[1], t0);
        break;
    }
    case DT_CMD_STOP:          judge_stop(); break;
    case DT_CMD_CALIBRATE:     fusion_calibrate(); break;
    case DT_CMD_BUZZ_TEST:     { uint8_t p = len > 1 ? data[1] : DT_HAPTIC_LONG; xQueueSend(haptic_q, &p, 0); } break;
    case DT_CMD_SET_THRESHOLD: if (len > 1) judge_set_threshold(data[1]); break;
    case DT_CMD_SET_WINDOW:    if (len > 2) { uint16_t w; memcpy(&w, data + 1, 2); judge_set_window(w); } break;
    case DT_CMD_SELFTEST:      model_selftest(); break;
    default: return;
    }
    push_status();
}

static void on_connect(uint16_t h)
{
    conn_hdl = h;
    BLEConnection *c = Bluefruit.Connection(h);
    c->requestConnectionParameter(12);   // 15 ms, units of 1.25 ms
    DT_LOGI(TAG, "connected, mtu %u", c->getMtu());
}

static void on_disconnect(uint16_t, uint8_t reason)
{
    conn_hdl = BLE_CONN_HANDLE_INVALID;
    judge_stop();
    DT_LOGI(TAG, "disconnected (0x%02x)", reason);
}

static int16_t q16(float v, float full_scale)
{
    float x = v / full_scale * 32767.0f;
    if (x > 32767.0f) x = 32767.0f;
    if (x < -32768.0f) x = -32768.0f;
    return (int16_t)x;
}

static void pack_quat(dt_stream_sample_t *s, const fused_sample_t *f)
{
    s->qw = q16(f->qw, 2.0f); s->qx = q16(f->qx, 2.0f);   // ×1/16384
    s->qy = q16(f->qy, 2.0f); s->qz = q16(f->qz, 2.0f);
}

// Drains event_q into Step event notifications.
static void event_task(void *)
{
    dt_step_event_t e;
    for (;;) {
        if (xQueueReceive(event_q, &e, portMAX_DELAY) != pdTRUE) continue;
        if (ble_connected()) chr_event.notify(&e, sizeof e);
    }
}

// Every 100 ms, send what the fusion ring produced since the last tick.
//   idle / dance: 5 samples at 50 Hz (every 2nd), quaternion + foot-frame accel (mg).
//   capture:      10 samples at 100 Hz as two accel batches (aligned sensor
//                 frame, mg) and two gyro batches (qw = DT_GYRO_PACKET_MARK,
//                 ax..az = dps × 10).
static void stream_task(void *)
{
    uint32_t next = fusion_count();
    TickType_t last = xTaskGetTickCount();
    for (;;) {
        vTaskDelayUntil(&last, pdMS_TO_TICKS(100));
        uint32_t end = fusion_count();
        if (!ble_connected() || !chr_stream.notifyEnabled()) { next = end; continue; }
        if (end - next > FUSION_RING_LEN) next = end - 10;   // fell behind; resync
        bool capture = judge_mode() == DT_MODE_CAPTURE;
        uint32_t step = capture ? 1 : 2;

        fused_sample_t f;
        dt_stream_batch_t acc, gyr;
        int n = 0;
        for (uint32_t i = next; i < end; i += step) {
            if (!fusion_get(i, &f)) continue;
            if (n == 0) { acc.t0_node_us = f.t_us; gyr.t0_node_us = f.t_us; }
            dt_stream_sample_t *a = &acc.s[n];
            pack_quat(a, &f);
            if (capture) {
                a->ax = (int16_t)(f.raw.ax * 1000); a->ay = (int16_t)(f.raw.ay * 1000); a->az = (int16_t)(f.raw.az * 1000);
                dt_stream_sample_t *g = &gyr.s[n];
                g->qw = DT_GYRO_PACKET_MARK; g->qx = g->qy = g->qz = 0;
                g->ax = (int16_t)(f.raw.gx * 10); g->ay = (int16_t)(f.raw.gy * 10); g->az = (int16_t)(f.raw.gz * 10);
            } else {
                a->ax = (int16_t)(f.ax_f * 1000); a->ay = (int16_t)(f.ay_f * 1000); a->az = (int16_t)(f.az_f * 1000);
            }
            if (++n == DT_STREAM_SAMPLES) {
                chr_stream.notify(&acc, sizeof acc);
                if (capture) chr_stream.notify(&gyr, sizeof gyr);
                n = 0;
            }
        }
        next = end;   // a partial batch is dropped; the next tick starts fresh
    }
}

// Refreshes battery + mode in Status every 2 s.
static void status_task(void *)
{
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(2000));
        push_status();
    }
}

void ble_init(dt_role_t role)
{
    g_role = role;

    Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);   // MTU 247: a 74-byte stream batch per notification
    Bluefruit.begin(1, 0);
    Bluefruit.setTxPower(4);
    Bluefruit.setName(role == DT_ROLE_LEFT ? "DT-L" : "DT-R");
    Bluefruit.Periph.setConnInterval(12, 24);        // 15–30 ms
    Bluefruit.Periph.setConnectCallback(on_connect);
    Bluefruit.Periph.setDisconnectCallback(on_disconnect);

    svc.begin();

    chr_status.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
    chr_status.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    chr_status.setFixedLen(sizeof(dt_status_t));
    chr_status.begin();

    chr_timesync.setProperties(CHR_PROPS_WRITE_WO_RESP | CHR_PROPS_WRITE | CHR_PROPS_NOTIFY);
    chr_timesync.setPermission(SECMODE_OPEN, SECMODE_OPEN);
    chr_timesync.setMaxLen(sizeof(dt_timesync_reply_t));
    chr_timesync.setWriteCallback(on_timesync, false);   // reply from the BLE task: no extra hop
    chr_timesync.begin();

    chr_schedule.setProperties(CHR_PROPS_WRITE);
    chr_schedule.setPermission(SECMODE_OPEN, SECMODE_OPEN);
    chr_schedule.setMaxLen(244);
    chr_schedule.setWriteCallback(on_schedule);
    chr_schedule.begin();

    chr_control.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
    chr_control.setPermission(SECMODE_OPEN, SECMODE_OPEN);
    chr_control.setMaxLen(8);
    chr_control.setWriteCallback(on_control);            // deferred: calibrate blocks 2 s
    chr_control.begin();

    chr_event.setProperties(CHR_PROPS_NOTIFY);
    chr_event.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    chr_event.setFixedLen(sizeof(dt_step_event_t));
    chr_event.begin();

    chr_stream.setProperties(CHR_PROPS_NOTIFY);
    chr_stream.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    chr_stream.setMaxLen(sizeof(dt_stream_batch_t));
    chr_stream.begin();

    push_status();

    Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
    Bluefruit.Advertising.addTxPower();
    Bluefruit.Advertising.addName();
    Bluefruit.ScanResponse.addService(svc);
    Bluefruit.Advertising.restartOnDisconnect(true);
    Bluefruit.Advertising.setInterval(32, 244);      // 20 ms fast, 152.5 ms slow
    Bluefruit.Advertising.setFastTimeout(30);
    Bluefruit.Advertising.start(0);

    xTaskCreate(event_task,  "ble_evt",    512, NULL, TASK_PRIO_NORMAL, NULL);
    xTaskCreate(stream_task, "ble_stream", 768, NULL, TASK_PRIO_NORMAL, NULL);
    xTaskCreate(status_task, "ble_status", 512, NULL, TASK_PRIO_LOW,    NULL);
    DT_LOGI(TAG, "advertising as %s", role == DT_ROLE_LEFT ? "DT-L" : "DT-R");
}
