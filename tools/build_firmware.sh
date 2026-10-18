#!/usr/bin/env bash
# Compatibility entry point for the ESP32 firmware.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
exec bash "$root/devices/esp32/tools/build.sh" "$@"
