#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p .build/fixtures
python3 devices/esp32/tests/protocol/generate_fixtures.py .build/fixtures
cc=${CC:-gcc}
"$cc" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I devices/esp32/shared/protocol/include -I .build/fixtures \
  devices/esp32/shared/protocol/bridge_io.c devices/esp32/shared/protocol/bridge_bplist.c \
  devices/esp32/tests/protocol/test_core.c -o .build/test_core
ASAN_OPTIONS=detect_leaks=0 .build/test_core
