// Host harness for test/firmware_protocol_test.dart: the firmware's judge.c, built
// for the host with the FreeRTOS stubs in this folder, plus copies of ble.cpp's
// on_schedule / on_control / q16 (keep them in step with ble.cpp).
//
// stdout: fixed STATUS / TS / BATCH / GYRO structs as hex, then per stdin line:
//   S <hex>               a schedule packet       (J/JS lines after a start)
//   C <hex>               a control packet
//   K <now> <t_strike> <cls> <conf>   a detected strike (E <hex> event out)
//   T <now>               run the missed-step check
#include "judge.c"
#include <stdio.h>
QueueHandle_t window_q = (void *)1, haptic_q = (void *)2, event_q = (void *)3;
uint32_t now_us = 0; uint8_t next_cls = 0, next_conf = 0;
static void hex(const char *tag, const void *p, int n) {
    printf("%s ", tag); for (int i = 0; i < n; i++) printf("%02x", ((const uint8_t *)p)[i]); printf("\n"); }
int xQueueSend(QueueHandle_t q, const void *item, uint32_t t) {
    if (q == event_q) hex("E", item, sizeof(dt_step_event_t));
    return 1; }
int xQueueReceive(QueueHandle_t q, void *item, uint32_t t) { return 0; }
uint32_t dt_now_us(void) { return now_us; }
void dt_log(char level, const char *tag, const char *fmt, ...) {}
dt_step_class_t classify(const step_window_t *w, uint16_t vocab, uint8_t *c) { (void)vocab; *c = next_conf; return next_cls; }

// ---- copied from ble.cpp ----
static void on_schedule(uint8_t *data, uint16_t len)
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
static void on_control(uint8_t *data, uint16_t len)
{
    if (len < 1) return;
    switch (data[0]) {
    case DT_CMD_START: { if (len < 6) return; uint32_t t0; memcpy(&t0, data + 2, 4); judge_start((dt_mode_t)data[1], t0); break; }
    case DT_CMD_STOP: judge_stop(); break;
    case DT_CMD_SET_THRESHOLD: if (len > 1) judge_set_threshold(data[1]); break;
    case DT_CMD_SET_WINDOW: if (len > 2) { uint16_t w; memcpy(&w, data + 1, 2); judge_set_window(w); } break;
    default: printf("CMD %u len %u\n", data[0], len); return;
    }
}
static int16_t q16(float v, float full_scale)
{
    float x = v / full_scale * 32767.0f;
    if (x > 32767.0f) x = 32767.0f;
    if (x < -32768.0f) x = -32768.0f;
    return (int16_t)x;
}
// ------------------------------

static int unhex(const char *s, uint8_t *out) { int n = 0; unsigned b; while (sscanf(s, "%2x", &b) == 1) { out[n++] = b; s += 2; } return n; }

int main(void) {
    judge_init();
    // Fixed structs for the parser checks.
    dt_status_t st = { DT_PROTOCOL_VERSION, DT_ROLE_RIGHT, (0 << 8) | 7, 83, DT_MODE_DANCE,
                       DT_CALF_STILL | DT_CALF_FORWARD, DT_CAL_RETURN, 2, 11 };
    hex("STATUS", &st, sizeof st);
    dt_timesync_reply_t ts = { 0xfedcba98u, 0x89abcdefu };
    hex("TS", &ts, sizeof ts);
    dt_stream_batch_t b; b.t0_node_us = 0xfffffff0u;
    float q[5][4] = {{1,0,0,0},{0.7071f,0.7071f,0,0},{0.5f,-0.5f,0.5f,-0.5f},{-1,0,0,0},{0.9998f,0.01f,-0.01f,0.0f}};
    for (int i = 0; i < 5; i++) {
        b.s[i].qw = q16(q[i][0], 2.0f); b.s[i].qx = q16(q[i][1], 2.0f); b.s[i].qy = q16(q[i][2], 2.0f); b.s[i].qz = q16(q[i][3], 2.0f);
        b.s[i].ax = (int16_t)(-1.234f * 1000); b.s[i].ay = (int16_t)(15.9f * 1000); b.s[i].az = (int16_t)(i * 100);
    }
    hex("BATCH", &b, sizeof b);
    dt_stream_batch_t g = b; for (int i = 0; i < 5; i++) { g.s[i].qw = DT_GYRO_PACKET_MARK; g.s[i].qx = g.s[i].qy = g.s[i].qz = 0;
        g.s[i].ax = (int16_t)(-1999.9f * 10); g.s[i].ay = (int16_t)(2000.0f * 10); g.s[i].az = 7; }
    hex("GYRO", &g, sizeof g);

    char line[4096]; uint8_t buf[2048];
    while (fgets(line, sizeof line, stdin)) {
        if (line[0] == 'S') { int n = unhex(line + 2, buf); on_schedule(buf, n); }
        else if (line[0] == 'C') { int n = unhex(line + 2, buf); on_control(buf, n);
            if (buf[0] == DT_CMD_START) { printf("J bpm_x10=%u n=%d t0=%u mode=%d\n", J.bpm_x10, J.n, J.t0_us, J.mode);
                for (int i = 0; i < J.n; i++) printf("JS %u %u\n", J.steps[i].t_us, J.steps[i].cls); } }
        else if (line[0] == 'K') { unsigned now, ts_, cls, conf; sscanf(line + 2, "%u %u %u %u", &now, &ts_, &cls, &conf);
            now_us = now; static step_window_t w; w.t_strike_us = ts_; next_cls = cls; next_conf = conf; judge_step(&w); }
        else if (line[0] == 'T') { unsigned now; sscanf(line + 2, "%u", &now); now_us = now; check_missed(); }
    }
    return 0;
}
