#include "dt_port.h"
#include <Arduino.h>
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>
#include <stdarg.h>
#include <stdio.h>

static SemaphoreHandle_t log_mutex;

void port_init(void)
{
    log_mutex = xSemaphoreCreateMutex();

    // TIMER4 as a 32-bit 1 MHz free-running counter. TIMER0 belongs to the
    // SoftDevice, TIMER2 CC[0] is read at boot by the core. The core's micros()
    // wraps every 67 s when the DWT cycle counter is on, so it is not usable.
    // TODO(power): move to RTC2 so the HF clock can stop between samples.
    NRF_TIMER4->TASKS_STOP = 1;
    NRF_TIMER4->MODE = TIMER_MODE_MODE_Timer;
    NRF_TIMER4->BITMODE = TIMER_BITMODE_BITMODE_32Bit << TIMER_BITMODE_BITMODE_Pos;
    NRF_TIMER4->PRESCALER = 4;   // 16 MHz / 2^4
    NRF_TIMER4->TASKS_CLEAR = 1;
    NRF_TIMER4->TASKS_START = 1;

    InternalFS.begin();
}

uint32_t dt_now_us(void)
{
    NRF_TIMER4->TASKS_CAPTURE[1] = 1;
    return NRF_TIMER4->CC[1];
}

dt_role_t dt_role(void)
{
    static int cached = -1;
    if (cached < 0) {
        char r = 0;
        if (storage_load("role", &r, 1) && (r == 'L' || r == 'R')) cached = (r == 'R');
        else
#ifdef DT_DEFAULT_ROLE_RIGHT
            cached = 1;
#else
            cached = 0;
#endif
    }
    return cached ? DT_ROLE_RIGHT : DT_ROLE_LEFT;
}

void dt_log(char level, const char *tag, const char *fmt, ...)
{
    char buf[160];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (log_mutex) xSemaphoreTake(log_mutex, pdMS_TO_TICKS(50));
    Serial.printf("%c (%lu) %s: %s\n", level, (unsigned long)millis(), tag, buf);
    if (log_mutex) xSemaphoreGive(log_mutex);
}

static void path_of(const char *name, char *out, size_t n) { snprintf(out, n, "/dt/%s.bin", name); }

bool storage_load(const char *name, void *buf, uint32_t len)
{
    char path[48];
    path_of(name, path, sizeof path);
    Adafruit_LittleFS_Namespace::File f(InternalFS);
    if (!f.open(path, Adafruit_LittleFS_Namespace::FILE_O_READ)) return false;
    bool ok = (uint32_t)f.size() == len && f.read(buf, len) == (int)len;
    f.close();
    return ok;
}

bool storage_save(const char *name, const void *buf, uint32_t len)
{
    char path[48];
    path_of(name, path, sizeof path);
    if (!InternalFS.exists("/dt")) InternalFS.mkdir("/dt");
    if (InternalFS.exists(path)) InternalFS.remove(path);
    Adafruit_LittleFS_Namespace::File f(InternalFS);
    if (!f.open(path, Adafruit_LittleFS_Namespace::FILE_O_WRITE)) return false;
    bool ok = f.write((const uint8_t *)buf, len) == len;
    f.close();
    return ok;
}
