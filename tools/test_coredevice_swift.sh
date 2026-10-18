#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$root/.build/coredevice-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/coredevice-module-cache"
bash "$root/tools/build_coredevice_rust.sh" host
exec swift test --disable-sandbox --package-path "$root/coredevice/swift" \
 --scratch-path "$root/.build/coredevice-swift" --cache-path "$root/.build/swift-cache"
