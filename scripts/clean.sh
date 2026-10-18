#!/bin/zsh
# Removes build products. --all also removes the third-party builds and download cache
# (scripts/build-deps.sh recreates them).
set -euo pipefail
source "${0:A:h}/_env.sh"

_afar_remove_staged_app
rm -rf "$ROOT/build" "$ROOT/.build" "$ROOT/.swiftpm"
if [[ "${1:-}" == "--all" ]]; then
    rm -rf "$VENDOR/prefix" "$VENDOR/.work" "$VENDOR/.cache"
fi
echo "Cleaned"
