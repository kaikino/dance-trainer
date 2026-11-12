#pragma once
int xQueueSend(QueueHandle_t q, const void *item, uint32_t ticks);
int xQueueReceive(QueueHandle_t q, void *item, uint32_t ticks);
