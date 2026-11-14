#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/test_core.sh" --remote "$@"
