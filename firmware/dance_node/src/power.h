#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void     power_init(void);       // enables the battery divider, sets charge current
uint16_t battery_mv(void);       // cell voltage, mV
uint8_t  battery_pct(void);      // 0–100 from a LiPo curve

#ifdef __cplusplus
}
#endif
