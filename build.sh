#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
if [[ -z ${XCODE_APP:-} ]]; then
    for candidate in /Applications/Xcode-27*.app(N) /Applications/Xcode.app(N); do
        version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$version" == 27* ]]; then
            XCODE_APP=$candidate
            break
        fi
    done
fi

XCODE_APP=${XCODE_APP:-/Applications/Xcode-27.0.0-beta.5.app}
DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
FRAMEWORKS="$XCODE_APP/Contents/SharedFrameworks"
BUILD_DIR="$ROOT/.build"
MODULE_DIR="$BUILD_DIR/modules"
APP="$BUILD_DIR/DeviceCanvas.app"
CONTENTS="$APP/Contents"

if [[ ! -d "$XCODE_APP" ]]; then
    print -u2 "Xcode not found: $XCODE_APP"
    exit 1
fi

SDK=$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path)

mkdir -p "$MODULE_DIR" "$CONTENTS/MacOS"

# DeviceKit ships without a .swiftmodule. Build a resilient compile-time module
# with matching public declarations, then resolve its symbols from the real
# framework at link and runtime.
DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swiftc \
    "$ROOT/DeviceKitShim.swift" \
    -parse-as-library \
    -emit-module \
    -enable-library-evolution \
    -module-name DeviceKit \
    -emit-module-path "$MODULE_DIR/DeviceKit.swiftmodule" \
    -sdk "$SDK" \
    -target arm64-apple-macos26.4

DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swiftc \
    "$ROOT/DeviceCanvas.swift" \
    "$ROOT/AndroidEmulator.swift" \
    -parse-as-library \
    -I "$MODULE_DIR" \
    -F "$FRAMEWORKS" \
    -framework DeviceKit \
    -Xlinker -rpath \
    -Xlinker "$FRAMEWORKS" \
    -sdk "$SDK" \
    -target arm64-apple-macos26.4 \
    -o "$CONTENTS/MacOS/DeviceCanvas"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
codesign --force --sign - "$APP"

print "$APP"
