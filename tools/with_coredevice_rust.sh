#!/usr/bin/env bash
# Use an installed Rust compiler; outputs stay in this worktree.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
toolchain="${COREDEVICE_RUST_TOOLCHAIN:-}"
if [[ -z "$toolchain" ]]; then
    if command -v rustc >/dev/null 2>&1; then
        toolchain=$(rustc --print sysroot)
    elif [[ -x "${HOME}/.cargo/bin/rustc" ]]; then
        toolchain=$("${HOME}/.cargo/bin/rustc" --print sysroot)
    fi
fi
if [[ -z "$toolchain" || ! -x "$toolchain/bin/cargo" || ! -x "$toolchain/bin/rustc" ]]; then
    echo 'error: Rust toolchain not found. Install Rust or set COREDEVICE_RUST_TOOLCHAIN to an installed toolchain directory.' >&2
    exit 1
fi
export PATH="$toolchain/bin:$PATH"
export RUSTC="$toolchain/bin/rustc"
export RUSTDOC="$toolchain/bin/rustdoc"
export CARGO_HOME="${COREDEVICE_CARGO_HOME:-${CARGO_HOME:-${HOME}/.cargo}}"
export CARGO_TARGET_DIR="${COREDEVICE_RUST_TARGET_DIR:-$root/.build/coredevice-rust}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec "$@"
