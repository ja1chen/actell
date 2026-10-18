#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
build="$root/.build/ncm-tests"
mkdir -p "$build"
idf="${IDF_PATH:-$root/.build/toolchains/esp-idf-v5.5.5}"
core="$root/devices/esp32/shared/protocol"
json="$idf/components/json/cJSON"
if [[ ! -f "$json/cJSON.c" ]]; then
  echo 'Set IDF_PATH to an installed ESP-IDF 5.5.5 directory for the cJSON test dependency.' >&2
  exit 1
fi
${CC:-clang} -std=c11 -g -O1 -Wno-deprecated-declarations -fsanitize=address,undefined -I "$json" -c "$json/cJSON.c" -o "$build/cJSON.o"
${CC:-clang} -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I devices/esp32/shared/ncm -I "$core/include" -I "$json" devices/esp32/tests/ncm/test_core.c devices/esp32/shared/ncm/{nd_discovery,nd_pairing,nd_socket,nd_server,nd_http,nd_relay}.c \
 "$core"/{bridge_io,bridge_bplist,bridge_lockdown_probe}.c \
 "$build/cJSON.o" -o "$build/core"
"$build/core"
${CC:-clang} -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I devices/esp32/shared/ncm -I "$core/include" -I "$json" devices/esp32/tests/ncm/test_socket.c \
 devices/esp32/shared/ncm/{nd_discovery,nd_pairing,nd_socket,nd_server}.c \
 "$core"/{bridge_io,bridge_bplist,bridge_lockdown_probe}.c "$build/cJSON.o" \
 -pthread -o "$build/socket"
"$build/socket"
${CC:-clang} -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I devices/esp32/shared/ncm -I "$core/include" -I "$json" devices/esp32/tests/ncm/test_relay.c \
 devices/esp32/shared/ncm/{nd_discovery,nd_socket,nd_relay}.c "$core/bridge_io.c" \
 -pthread -o "$build/relay"
"$build/relay"
