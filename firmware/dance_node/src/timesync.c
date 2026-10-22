#include "timesync.h"
#include "dt_port.h"

void timesync_init(void) {}

void timesync_reply(uint32_t t_app_ms, dt_timesync_reply_t *out)
{
    out->t_app_ms = t_app_ms;
    out->t_node_us = dt_now_us();
}
