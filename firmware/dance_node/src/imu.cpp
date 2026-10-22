// LSM6DS3TR-C, the IMU soldered onto the XIAO nRF52840 Sense. Register layout is
// the LSM6DS family's (ST datasheet DS11912); only WHO_AM_I differs from the LSM6DSOX.
#include "imu.h"
#include "board.h"
#include "dt_port.h"
#include <Arduino.h>
#include <Wire.h>

static const char *TAG = "imu";
extern QueueHandle_t sample_q;

#define REG_WHO_AM_I   0x0F  // 0x6A on LSM6DS3TR-C, 0x69 on LSM6DS3, 0x6C on LSM6DSOX
#define REG_CTRL1_XL   0x10  // ODR_XL[7:4]=0100 (104 Hz), FS_XL[3:2]=01 (±16 g)
#define REG_CTRL2_G    0x11  // ODR_G[7:4]=0100 (104 Hz), FS_G[3:2]=11 (±2000 dps)
#define REG_CTRL3_C    0x12  // BDU=1, IF_INC=1
#define REG_INT1_CTRL  0x0D  // INT1_DRDY_XL=1
#define REG_OUTX_L_G   0x22  // 12 bytes: gx,gy,gz,ax,ay,az (int16 each)

#define ACC_SENS_G   (0.488f / 1000.0f)   // ±16 g: 0.488 mg/LSB
#define GYR_SENS_DPS (70.0f / 1000.0f)    // ±2000 dps: 70 mdps/LSB

static SemaphoreHandle_t drdy_sem;
static volatile uint32_t drdy_t_us;

static bool wr(uint8_t reg, uint8_t val)
{
    BOARD_IMU_WIRE.beginTransmission(BOARD_IMU_ADDR);
    BOARD_IMU_WIRE.write(reg);
    BOARD_IMU_WIRE.write(val);
    return BOARD_IMU_WIRE.endTransmission() == 0;
}

static bool rd(uint8_t reg, uint8_t *buf, size_t n)
{
    BOARD_IMU_WIRE.beginTransmission(BOARD_IMU_ADDR);
    BOARD_IMU_WIRE.write(reg);
    if (BOARD_IMU_WIRE.endTransmission(false) != 0) return false;
    if (BOARD_IMU_WIRE.requestFrom((uint8_t)BOARD_IMU_ADDR, n) != n) return false;
    for (size_t i = 0; i < n; i++) buf[i] = BOARD_IMU_WIRE.read();
    return true;
}

static void drdy_isr(void)
{
    drdy_t_us = dt_now_us();
    BaseType_t woken = pdFALSE;
    xSemaphoreGiveFromISR(drdy_sem, &woken);
    portYIELD_FROM_ISR(woken);
}

bool imu_init(void)
{
    pinMode(BOARD_IMU_PWR, OUTPUT);
    digitalWrite(BOARD_IMU_PWR, HIGH);
    delay(20);   // boot time after power-up, datasheet 15 ms
    BOARD_IMU_WIRE.begin();
    BOARD_IMU_WIRE.setClock(400000);

    uint8_t who = 0;
    if (!rd(REG_WHO_AM_I, &who, 1)) { DT_LOGE(TAG, "no I2C answer at 0x%02x", BOARD_IMU_ADDR); return false; }
    if (who != 0x6A && who != 0x69 && who != 0x6C) { DT_LOGE(TAG, "WHO_AM_I=0x%02x", who); return false; }

    bool ok = wr(REG_CTRL3_C, 0x44) && wr(REG_CTRL1_XL, 0x44) && wr(REG_CTRL2_G, 0x4C) && wr(REG_INT1_CTRL, 0x01);
    if (!ok) { DT_LOGE(TAG, "config write failed"); return false; }

    drdy_sem = xSemaphoreCreateBinary();
    pinMode(BOARD_IMU_INT1, INPUT);
    attachInterrupt(digitalPinToInterrupt(BOARD_IMU_INT1), drdy_isr, RISING);
    DT_LOGI(TAG, "LSM6DS3TR-C ready (who=0x%02x)", who);
    return true;
}

void imu_task(void *arg)
{
    uint8_t raw[12];
    int timeouts = 0;
    for (;;) {
        if (xSemaphoreTake(drdy_sem, pdMS_TO_TICKS(100)) != pdTRUE) {
            // A missed edge leaves INT1 latched high; reading the outputs clears it.
            if (timeouts++ == 0) DT_LOGW(TAG, "no data-ready for 100 ms, polling");
            drdy_t_us = dt_now_us();
        }
        imu_sample_t s = { .t_us = drdy_t_us };
        if (!rd(REG_OUTX_L_G, raw, sizeof raw)) continue;

        int16_t g[3], a[3];
        for (int i = 0; i < 3; i++) {
            g[i] = (int16_t)(raw[2 * i] | (raw[2 * i + 1] << 8));
            a[i] = (int16_t)(raw[6 + 2 * i] | (raw[7 + 2 * i] << 8));
        }
        s.gx = g[0] * GYR_SENS_DPS; s.gy = g[1] * GYR_SENS_DPS; s.gz = g[2] * GYR_SENS_DPS;
        s.ax = a[0] * ACC_SENS_G;   s.ay = a[1] * ACC_SENS_G;   s.az = a[2] * ACC_SENS_G;

        if (xQueueSend(sample_q, &s, 0) != pdTRUE) DT_LOGW(TAG, "sample_q full");
    }
}
