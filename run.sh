#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
APP="$ROOT/.build/DeviceHubTiler.app"
device_identifiers=("$@")

if [[ ! -d "$APP" ]]; then
    zsh "$ROOT/build.sh"
fi

if (( ${#device_identifiers} == 0 )); then
    in_ios_section=false

    while IFS= read -r line; do
        if [[ "$line" == "-- iOS "* ]]; then
            in_ios_section=true
        elif [[ "$line" == "-- "* ]]; then
            in_ios_section=false
        elif $in_ios_section && [[ "$line" =~ '\(([0-9A-F-]{36})\) \(Booted\)' ]]; then
            device_identifiers+=("$match[1]")
        fi
    done <<< "$(xcrun simctl list devices booted)"
fi

if (( ${#device_identifiers} < 2 )); then
    print -u2 "Boot at least two iOS simulators or pass two simulator UDIDs."
    exit 1
fi

open -n "$APP" --args "${device_identifiers[@]}"
