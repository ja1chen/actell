#!/usr/bin/env bash
# In-memory and loopback peers only. No device access, key reads or persistent keys.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
bash tools/with_coredevice_rust.sh cargo test --offline --locked --manifest-path coredevice/rust/Cargo.toml -p coredevice-backend
bash tools/with_coredevice_rust.sh cargo test --offline --locked --manifest-path coredevice/rust/Cargo.toml -p idevice --lib --features ring,remote_pairing,tunnel_tcp_stack,display_stream,mobile_image_mounter
