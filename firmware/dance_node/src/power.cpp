#include "power.h"
#include "board.h"
#include "dt_port.h"
#include <Arduino.h>

static const char *TAG = "power";

void power_init(void)
{
    pinMode(BOARD_VBAT_ENABLE, OUTPUT);
    digitalWrite(BOARD_VBAT_ENABLE, LOW);        // connect the divider
    pinMode(BOARD_CHG_CURRENT, OUTPUT);
    digitalWrite(BOARD_CHG_CURRENT, LOW);        // 100 mA charge; fine for ≥150 mAh cells
    analogReference(AR_INTERNAL_3_0);
    analogReadResolution(12);
    DT_LOGI(TAG, "battery %u mV", battery_mv());
}

uint16_t battery_mv(void)
{
    uint32_t sum = 0;
    for (int i = 0; i < 8; i++) sum += analogRead(BOARD_VBAT_PIN);
    uint32_t mv_pin = (sum / 8) * 3000 / 4095;
    return (uint16_t)(mv_pin * 1510 / 510);       // 1 MΩ over 510 kΩ
}

uint8_t battery_pct(void)
{
    static const uint16_t mv_pts[]  = {3300, 3500, 3600, 3700, 3800, 3900, 4000, 4100, 4200};
    static const uint8_t  pct_pts[] = {   0,    5,   15,   35,   55,   70,   85,   95,  100};
    uint16_t mv = battery_mv();
    if (mv <= mv_pts[0]) return 0;
    for (int i = 1; i < 9; i++) {
        if (mv <= mv_pts[i])
            return pct_pts[i - 1] + (pct_pts[i] - pct_pts[i - 1]) * (mv - mv_pts[i - 1]) / (mv_pts[i] - mv_pts[i - 1]);
    }
    return 100;
}
