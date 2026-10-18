#!/bin/zsh
# Runs the unit tests.
set -euo pipefail
source "${0:A:h}/_env.sh"
[[ -f "$PREFIX/lib/libAfarFreeRDP.a" ]] || "$ROOT/scripts/build-deps.sh"
swift test "$@"
