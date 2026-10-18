// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
esp_err_t developer_service_start(bool (*online)(void), uint32_t (*epoch)(void), uint32_t interface_index);
