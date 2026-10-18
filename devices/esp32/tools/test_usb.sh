#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
mkdir -p "$root/.build/usb-device-tests"
${CC:-clang} -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  -I"$root/devices/esp32/shared/usb" -I"$root/devices/esp32/shared/ncm" "$root/devices/esp32/tests/usb/test_protocol.c" \
  "$root/devices/esp32/shared/usb/protocol.c" "$root/devices/esp32/shared/usb/hid_motion.c" \
  -o "$root/.build/usb-device-tests/protocol"
"$root/.build/usb-device-tests/protocol"
${CC:-clang} -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -fsanitize=address,undefined -g \
  -I"$root/devices/esp32/tests/usb/host_stubs" -I"$root/devices/esp32/shared/usb" -I"$root/devices/esp32/shared/ncm" \
  "$root/devices/esp32/tests/usb/host_server.c" "$root/devices/esp32/firmware/main/main.c" "$root/devices/esp32/shared/usb/usb_control.c" \
  "$root/devices/esp32/shared/usb/protocol.c" "$root/devices/esp32/shared/usb/hid_motion.c" \
  -o "$root/.build/usb-device-tests/server"
python3 "$root/devices/esp32/tests/usb/test_tcp.py"
