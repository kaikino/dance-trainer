#pragma once
// Wire format for the Dance Trainer BLE service. Mirrors docs/ble-protocol.md.
// Any change here must change docs/ble-protocol.md and app/lib/ble/protocol.dart.

#include <stdint.h>

#define DT_PROTOCOL_VERSION 1

// UUID base 7d4eXXXX-5a1c-4b8e-9f3a-2c6d8e1f0a00; XXXX below.
#define DT_UUID_SERVICE    0x0001
#define DT_UUID_STATUS     0x0002
#define DT_UUID_TIMESYNC   0x0003
#define DT_UUID_SCHEDULE   0x0004
#define DT_UUID_CONTROL    0x0005
#define DT_UUID_STEP_EVENT 0x0006
#define DT_UUID_STREAM     0x0007

typedef enum {
    DT_CLASS_NONE = 0,
    DT_CLASS_IN_PLACE,
    DT_CLASS_FORWARD,
    DT_CLASS_BACK,
    DT_CLASS_SIDE_OUT,
    DT_CLASS_CROSS,
    DT_CLASS_KICK,
    DT_CLASS_COUNT
} dt_step_class_t;

typedef enum {
    DT_VERDICT_UNJUDGED = 0,
    DT_VERDICT_CORRECT,
    DT_VERDICT_OFF_BEAT,
    DT_VERDICT_WRONG_STEP,
    DT_VERDICT_MISSED,
    DT_VERDICT_EXTRA,
} dt_verdict_t;

typedef enum { DT_MODE_IDLE = 0, DT_MODE_CAPTURE, DT_MODE_DANCE } dt_mode_t;
typedef enum { DT_ROLE_LEFT = 0, DT_ROLE_RIGHT } dt_role_t;

typedef enum {
    DT_HAPTIC_SHORT = 1,   // timing error
    DT_HAPTIC_DOUBLE = 2,  // wrong step
    DT_HAPTIC_LONG = 3,    // test
} dt_haptic_t;

typedef enum {
    DT_CMD_START = 1,
    DT_CMD_STOP,
    DT_CMD_CALIBRATE,
    DT_CMD_BUZZ_TEST,
    DT_CMD_SET_THRESHOLD,
    DT_CMD_SET_WINDOW,
    DT_CMD_SELFTEST,
} dt_cmd_t;

#define DT_SCHED_FLAG_HEADER 0x01
#define DT_SCHED_FLAG_LAST   0x02
#define DT_SCHED_MAX_STEPS   256

typedef struct __attribute__((packed)) {
    uint8_t  protocol_version;
    uint8_t  role;
    uint16_t fw_version;   // major << 8 | minor
    uint8_t  battery_pct;
    uint8_t  mode;
} dt_status_t;             // 6 bytes

typedef struct __attribute__((packed)) {
    uint32_t t_app_ms;
    uint32_t t_node_us;
} dt_timesync_reply_t;     // 8 bytes

typedef struct __attribute__((packed)) {
    uint8_t  flags;
    uint16_t preset_id;
    uint16_t bpm_x10;
    uint16_t n_steps;
} dt_sched_header_t;       // 7 bytes

typedef struct __attribute__((packed)) {
    uint16_t beat_x100;
    uint8_t  step_class;
} dt_sched_step_t;         // 3 bytes

typedef struct __attribute__((packed)) {
    uint16_t seq;
    uint32_t t_strike_node_us;
    uint8_t  step_class;
    uint8_t  confidence;
    uint8_t  expected_class;
    int16_t  timing_err_ms;
    uint8_t  verdict;
} dt_step_event_t;         // 12 bytes

typedef struct __attribute__((packed)) {
    int16_t qw, qx, qy, qz;  // x 1/16384
    int16_t ax, ay, az;      // mg (world frame in dance mode, sensor frame in capture)
} dt_stream_sample_t;      // 14 bytes

#define DT_STREAM_SAMPLES 5
typedef struct __attribute__((packed)) {
    uint32_t t0_node_us;
    dt_stream_sample_t s[DT_STREAM_SAMPLES];
} dt_stream_batch_t;       // 74 bytes

#define DT_GYRO_PACKET_MARK 0x7FFF  // qw == this: ax..az hold gx..gz (dps x10)

#ifdef __cplusplus
#define DT_STATIC_ASSERT(c, m) static_assert(c, m)
#else
#define DT_STATIC_ASSERT(c, m) _Static_assert(c, m)
#endif
DT_STATIC_ASSERT(sizeof(dt_status_t) == 6, "status size");
DT_STATIC_ASSERT(sizeof(dt_step_event_t) == 12, "step event size");
DT_STATIC_ASSERT(sizeof(dt_stream_batch_t) == 74, "stream batch size");
