#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "protocol.h"
#include "esp_err.h"
esp_err_t usb_network_start(void);
uint32_t usb_network_index(void);
void usb_install(void);
uint32_t usb_epoch(void);
bool usb_online(void);
bool usb_hid_enabled(void);
bool usb_hid_start(const pa_command *command, int64_t now);
void usb_hid_cancel(void);
void usb_hid_tick(int64_t now);
bool usb_hid_neutral(void);
uint32_t usb_hid_completed(void);

void usb_control_run(void);
