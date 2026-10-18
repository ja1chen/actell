#!/usr/bin/env bash
# Use an installed SDK; keep generated component caches in this checkout.
set -eo pipefail
device_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
if [[ -z "${IDF_PATH:-}" ]]; then
  if [[ -f "$device_root/.build/toolchains/esp-idf-v5.5.5/export.sh" ]]; then
    export IDF_PATH="$device_root/.build/toolchains/esp-idf-v5.5.5"
    export IDF_TOOLS_PATH="${IDF_TOOLS_PATH:-$device_root/.build/toolchains/espressif}"
  elif command -v idf.py >/dev/null 2>&1; then
    export IDF_PATH="$(cd "$(dirname "$(command -v idf.py)")/.." && pwd)"
  fi
fi
if [[ ! -f "${IDF_PATH:-}/export.sh" ]]; then
  echo 'Set IDF_PATH to an installed ESP-IDF 5.5.5 directory (and IDF_TOOLS_PATH if needed).' >&2
  exit 1
fi
# Reuse a single installed 5.5 environment even when the shell's Python differs.
# Multiple environments require the caller to choose IDF_PYTHON_ENV_PATH.
if [[ -z "${IDF_PYTHON_ENV_PATH:-}" ]]; then
  shopt -s nullglob
  device_python_envs=("${IDF_TOOLS_PATH:-$HOME/.espressif}"/python_env/idf5.5_py*_env)
  shopt -u nullglob
  if [[ ${#device_python_envs[@]} -eq 1 && -x "${device_python_envs[0]}/bin/python" ]]; then
    export IDF_PYTHON_ENV_PATH="${device_python_envs[0]}"
  fi
fi
if [[ -n "${IDF_PYTHON_ENV_PATH:-}" ]]; then
  export PATH="$IDF_PYTHON_ENV_PATH/bin:$PATH"
fi
export IDF_COMPONENT_CACHE_PATH="$device_root/.build/component-cache"
source "$IDF_PATH/export.sh"
exec "$@"
