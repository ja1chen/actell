#!/usr/bin/env bash
# Build only; never flashes or opens a device.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
if [[ $# -gt 1 ]]; then echo 'Usage: build.sh [ncm|hid|diagnostic]' >&2; exit 2; fi
mode="${1:-ncm}"
case "$mode" in
  ncm|hid|diagnostic) ;;
  -h|--help) echo 'Usage: build.sh [ncm|hid|diagnostic] (default: ncm; build only)'; exit 0 ;;
  *) echo 'Usage: build.sh [ncm|hid|diagnostic]' >&2; exit 2 ;;
esac
base="$root/devices/esp32"
exec "$base/tools/with_idf.sh" idf.py -C "$base/firmware" \
  -B "$root/.build/esp32-$mode" -D "SDKCONFIG=$root/.build/esp32-$mode/sdkconfig" \
  -D "SDKCONFIG_DEFAULTS=$base/configs/defaults;$base/configs/$mode" build
