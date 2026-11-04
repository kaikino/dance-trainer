# Wiring (Seeed XIAO nRF52840 Sense Plus)

Only three external connections per node: the motor, the battery, the switch.

```
                 ┌──────────── XIAO nRF52840 Sense Plus ────────────┐
Grove motor VCC ─┤ 3V3                                              │
Grove motor GND ─┤ GND                                              │
Grove motor SIG ─┤ D9 (P1.14)                                       │
                 │                                    back pads:    │
LiPo (+) ── switch ─────────────────────────────────── BAT+        │
LiPo (−) ───────────────────────────────────────────── BAT−        │
                 └──────────────────────────────────────────────────┘
```

- **Motor.** The Grove module has the drive transistor and flyback diode on it,
  so SIG is a plain logic input. Cut one end off a Grove cable and solder the
  three wires to 3V3, GND and D9 (yellow, SIG). The fourth, white (NC), is unused;
  on our nodes it sits on D10, which the firmware leaves alone. The coin motor
  draws about 60–80 mA at 3.3 V; the board's regulator covers that.
- **Battery.** BAT+ and BAT− are solder pads on the underside. The onboard
  BQ25100 charges the cell from USB-C; the firmware selects 100 mA, suitable for
  150 mAh and up. Use a cell with its own protection circuit.
- **Switch.** In the BAT+ lead, so the node can be switched off without opening
  the case. The charger output is the BAT+ pad itself, so the switch must be on
  while charging over USB.
- **Battery sense.** Internal: P0.31 through a 1 MΩ / 510 kΩ divider, enabled
  by P0.14 low. Nothing to wire.
- **IMU.** Internal: LSM6DS3TR-C on P0.07 / P0.27 (`Wire1`), INT1 on P0.11,
  powered from P1.08. Nothing to wire.
- **Orientation.** Any orientation works as long as it does not change during
  the session: calibration measures which way is down (2 s still pose) and
  which way is forward (three slides of the foot), and rotates everything into a
  foot frame. Mounting with the USB-C port toward the toe is still the
  convention, because a node whose slides failed reports "tilt only" and
  falls back to assuming that. Left and right nodes are mirrored in firmware,
  so both boards mount the same way on their respective ankles.
- **Antenna.** The ceramic antenna is at the end opposite the USB-C port. Keep
  that end away from the battery and out of the strap's metal buckle if any.
