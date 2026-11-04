// Finds the motor: drives D0..D10 high one at a time for 1.5 s and prints the
// pin, then repeats. Watch the serial monitor and note which pin buzzes.
#include <Adafruit_TinyUSB.h>

static const int pins[] = {D0, D1, D2, D3, D4, D5, D6, D7, D8, D9, D10};

void setup() {
  Serial.begin(115200);
  for (int p : pins) { pinMode(p, OUTPUT); digitalWrite(p, LOW); }
}

void loop() {
  for (int i = 0; i < 11; i++) {
    Serial.printf("D%d on\n", i);
    digitalWrite(pins[i], HIGH);
    delay(1500);
    digitalWrite(pins[i], LOW);
    delay(500);
  }
  Serial.println("--- repeat ---");
}
