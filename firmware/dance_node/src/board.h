#pragma once
// Seeed XIAO nRF52840 Sense Plus. Onboard: LSM6DS3TR-C IMU on Wire1, BQ25100 LiPo
// charger, battery divider on PIN_VBAT. Pin indexes below are Arduino pin numbers
// from the board package's variant.h; physical names in hardware/wiring.md.
#include "variant.h"

#define BOARD_MOTOR_PIN      D0                      // Grove Vibration Motor SIG (P0.02)
#define BOARD_IMU_WIRE       Wire1                   // internal bus: P0.07 SDA, P0.27 SCL
#define BOARD_IMU_ADDR       0x6A
#define BOARD_IMU_PWR        PIN_LSM6DS3TR_C_POWER   // P1.08, drive HIGH
#define BOARD_IMU_INT1       PIN_LSM6DS3TR_C_INT1    // P0.11
#define BOARD_VBAT_PIN       PIN_VBAT                // P0.31, through 1 MΩ / 510 kΩ
#define BOARD_VBAT_ENABLE    VBAT_ENABLE             // P0.14, LOW enables the divider
#define BOARD_CHG_CURRENT    PIN_CHARGING_CURRENT    // P0.13, LOW = 100 mA, HIGH = 50 mA

#ifndef DT_FW_MAJOR
#define DT_FW_MAJOR 0
#endif
#ifndef DT_FW_MINOR
#define DT_FW_MINOR 2
#endif
