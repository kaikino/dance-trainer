// Stream the onboard LSM6DS3TR-C over USB serial as CSV, 50 Hz.
// Board: Seeed XIAO nRF52840 Sense Plus (Seeed nRF52 Boards core).
//
//   arduino-cli compile --fqbn Seeeduino:nrf52:xiaonRF52840SensePlus imu_stream
//   arduino-cli upload  --fqbn Seeeduino:nrf52:xiaonRF52840SensePlus -p /dev/cu.usbmodemXXXX imu_stream
//   python3 tools/imu_plot.py /dev/cu.usbmodemXXXX     (live plot)
//
// Output lines:  t_ms,ax,ay,az,gx,gy,gz   (g and deg/s)

#include <Adafruit_TinyUSB.h>
#include <Wire.h>

#define IMU_WIRE  Wire1                    // internal bus to the IMU
#define IMU_ADDR  0x6A
#define IMU_PWR   PIN_LSM6DS3TR_C_POWER    // P1.08, HIGH = IMU powered

#define REG_WHO_AM_I  0x0F
#define REG_CTRL1_XL  0x10
#define REG_CTRL2_G   0x11
#define REG_CTRL3_C   0x12
#define REG_OUTX_L_G  0x22

#define ACC_SENS_G    (0.488f / 1000.0f)   // ±16 g
#define GYR_SENS_DPS  (70.0f / 1000.0f)    // ±2000 dps

static bool wr(uint8_t reg, uint8_t val) {
  IMU_WIRE.beginTransmission(IMU_ADDR);
  IMU_WIRE.write(reg);
  IMU_WIRE.write(val);
  return IMU_WIRE.endTransmission() == 0;
}

static bool rd(uint8_t reg, uint8_t *buf, size_t n) {
  IMU_WIRE.beginTransmission(IMU_ADDR);
  IMU_WIRE.write(reg);
  if (IMU_WIRE.endTransmission(false) != 0) return false;
  if (IMU_WIRE.requestFrom((uint8_t)IMU_ADDR, n) != n) return false;
  for (size_t i = 0; i < n; i++) buf[i] = IMU_WIRE.read();
  return true;
}

void setup() {
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) {}   // wait for the monitor, but not forever

  Serial.println("# step 1: power on IMU");
  pinMode(IMU_PWR, OUTPUT);
  digitalWrite(IMU_PWR, HIGH);
  delay(50);
  Serial.println("# step 2: Wire1.begin");
  IMU_WIRE.begin();
  IMU_WIRE.setClock(100000);
  Serial.println("# step 3: WHO_AM_I");

  uint8_t who = 0;
  if (!rd(REG_WHO_AM_I, &who, 1)) {
    Serial.println("# ERROR: no I2C answer from IMU");
    while (true) delay(1000);
  }
  Serial.print("# WHO_AM_I=0x"); Serial.println(who, HEX);   // expect 0x6A

  wr(REG_CTRL3_C, 0x44);   // block data update, auto-increment
  wr(REG_CTRL1_XL, 0x44);  // accel 104 Hz, ±16 g
  wr(REG_CTRL2_G, 0x4C);   // gyro 104 Hz, ±2000 dps
  Serial.println("t_ms,ax,ay,az,gx,gy,gz");
}

void loop() {
  static uint32_t next = 0;
  uint32_t now = millis();
  if (now < next) return;
  next = now + 20;   // 50 Hz, plenty for a plot

  uint8_t raw[12];
  if (!rd(REG_OUTX_L_G, raw, sizeof raw)) return;
  int16_t v[6];
  for (int i = 0; i < 6; i++) v[i] = (int16_t)(raw[2 * i] | (raw[2 * i + 1] << 8));
  // register order is gx,gy,gz,ax,ay,az; print accel first
  Serial.print(now);
  Serial.print(','); Serial.print(v[3] * ACC_SENS_G, 3);
  Serial.print(','); Serial.print(v[4] * ACC_SENS_G, 3);
  Serial.print(','); Serial.print(v[5] * ACC_SENS_G, 3);
  Serial.print(','); Serial.print(v[0] * GYR_SENS_DPS, 1);
  Serial.print(','); Serial.print(v[1] * GYR_SENS_DPS, 1);
  Serial.print(','); Serial.println(v[2] * GYR_SENS_DPS, 1);
}
