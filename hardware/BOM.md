# Bill of materials

Per node, build two plus one spare of anything that can fail or get lost.

| # | Part | Example | Qty | ~Unit |
| --- | --- | --- | --- | --- |
| 1 | Seeed XIAO nRF52840 Sense Plus (nRF52840, BLE 5, LSM6DS3TR-C IMU, LiPo charger) | seeedstudio.com, "Sense Plus" variant | 3 | $17 |
| 2 | Grove Vibration Motor (coin ERM, driver on module) | Seeed 105020005 | 3 | $3 |
| 3 | Grove 4-pin cable, one end cut for soldering | Seeed 110990027 | 3 | $1 |
| 4 | LiPo 3.7 V, 150–250 mAh, protected, bare leads (e.g. 502030) | generic | 3 | $6 |
| 5 | Slide switch, SPDT, mini | generic | 3 | $1 |
| 6 | 28 AWG silicone wire, assorted | generic | 1 | $6 |
| 7 | Elastic strap 25 mm with hook-and-loop, or velcro ankle band | generic | 2 | $4 |
| 8 | 3D-printed case, ~35×25×12 mm with USB-C cutout | `enclosure/` | 2 | — |
| 9 | Foam tape / hot glue | | 1 | $3 |

Team-wide: USB-C cables (have), an Android phone for the app (have), 3D printer
access. About $100 before shipping.

Not needed with this board: external IMU, haptic driver IC, charger module, LDO,
battery divider resistors. Ordered 2026-10: two of #1, three of #2.

The ESP32-S3 fallback (git tag `esp-idf-last`) would add per node an LSM6DSOX
breakout, a TP4056 charger and an MCP1700 regulator; do not buy unless needed.
