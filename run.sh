#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
APP="$ROOT/.build/DeviceHubTiler.app"

if [[ ! -d "$APP" ]]; then
    zsh "$ROOT/build.sh"
fi

if (( $# > 0 )); then
    open -n "$APP" --args "$@"
else
    open -n "$APP"
fi
