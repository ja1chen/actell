#!/usr/bin/env bash
# Actual Swift -> C ABI -> Rust -> C relay -> synthetic peer. LOOPBACK ONLY.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .build/coredevice-tests
clang -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I devices/esp32/shared/ncm -I devices/esp32/shared/protocol/include \
 devices/esp32/tests/ncm/relay_fixture.c devices/esp32/shared/ncm/{nd_discovery,nd_socket,nd_relay}.c \
 devices/esp32/shared/protocol/bridge_io.c -pthread -o .build/coredevice-tests/relay_fixture
# Separate target directory ensures test-only exports cannot enter iOS artifacts.
COREDEVICE_RUST_TARGET_DIR="$root/.build/coredevice-rust-fixtures" bash tools/with_coredevice_rust.sh cargo build --offline --locked --manifest-path coredevice/rust/Cargo.toml --features offline-fixtures --release --target aarch64-apple-darwin
export COREDEVICE_OFFLINE_FIXTURES=1
export COREDEVICE_BACKEND_ARCHIVE_DIR="$root/.build/coredevice-rust-fixtures/aarch64-apple-darwin/release"
export COREDEVICE_RELAY_FIXTURE="$root/.build/coredevice-tests/relay_fixture"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$root/.build/coredevice-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/coredevice-module-cache"
swift test --disable-sandbox --package-path "$root/coredevice/swift" \
 --scratch-path "$root/.build/coredevice-swift-chain" --cache-path "$root/.build/swift-cache"
