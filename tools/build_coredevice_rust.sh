#!/usr/bin/env bash
# Static backend with C ABI; no signing, installation or device actions.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
case "${1:-device}" in
 device) target=aarch64-apple-ios ;;
 simulator) target=aarch64-apple-ios-sim ;;
 host) target=aarch64-apple-darwin ;;
 *) echo 'usage: build_coredevice_rust.sh [device|simulator|host]' >&2; exit 2 ;;
esac
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
cargo_flags=(--locked)
if [[ "${COREDEVICE_CARGO_OFFLINE:-0}" == 1 ]]; then cargo_flags+=(--offline); fi
bash tools/with_coredevice_rust.sh cargo build "${cargo_flags[@]}" --manifest-path coredevice/rust/Cargo.toml --release --target "$target"
