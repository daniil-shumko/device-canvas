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
PROTOCOL_TESTS="$BUILD_DIR/SesoriIntegrationTests"
WEBRTC_TESTS="$BUILD_DIR/AndroidWebRTCStreamTests"
WEBRTC_VERSION=151.0.0
WEBRTC_URL="https://github.com/stasel/WebRTC/releases/download/$WEBRTC_VERSION/WebRTC-M151.xcframework.zip"
WEBRTC_SHA256=64a218fad3d84a0d783321aa9a1eec58ca266ac7879123f86b0b44b703b7d8dc
DEPENDENCIES_DIR="$BUILD_DIR/dependencies"
WEBRTC_ARCHIVE="$DEPENDENCIES_DIR/WebRTC-M151.xcframework.zip"

if [[ ! -d "$XCODE_APP" ]]; then
    print -u2 "Xcode not found: $XCODE_APP"
    exit 1
fi

SDK=$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path)

mkdir -p "$MODULE_DIR" "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"

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
    "$ROOT/SesoriIntegration.swift" \
    "$ROOT/SesoriIntegrationTests.swift" \
    -parse-as-library \
    -sdk "$SDK" \
    -target arm64-apple-macos26.4 \
    -o "$PROTOCOL_TESTS"

"$PROTOCOL_TESTS"

if [[ -n ${WEBRTC_XCFRAMEWORK_PATH:-} ]]; then
    WEBRTC_XCFRAMEWORK="$WEBRTC_XCFRAMEWORK_PATH"
else
    WEBRTC_ROOT="$DEPENDENCIES_DIR/webrtc-$WEBRTC_VERSION"
    WEBRTC_XCFRAMEWORK="$WEBRTC_ROOT/WebRTC.xcframework"
    mkdir -p "$DEPENDENCIES_DIR" "$WEBRTC_ROOT"
    if [[ ! -f "$WEBRTC_ARCHIVE" ]]; then
        curl --fail --location --retry 3 --output "$WEBRTC_ARCHIVE" "$WEBRTC_URL"
    fi
    WEBRTC_ACTUAL_SHA256=$(shasum -a 256 "$WEBRTC_ARCHIVE")
    WEBRTC_ACTUAL_SHA256=${WEBRTC_ACTUAL_SHA256%% *}
    if [[ "$WEBRTC_ACTUAL_SHA256" != "$WEBRTC_SHA256" ]]; then
        print -u2 "WebRTC $WEBRTC_VERSION checksum mismatch"
        exit 1
    fi
    rm -rf "$WEBRTC_ROOT"
    mkdir -p "$WEBRTC_ROOT"
    ditto -x -k "$WEBRTC_ARCHIVE" "$WEBRTC_ROOT"
fi

WEBRTC_FRAMEWORK_DIR="$WEBRTC_XCFRAMEWORK/macos-x86_64_arm64"
WEBRTC_FRAMEWORK="$WEBRTC_FRAMEWORK_DIR/WebRTC.framework"
if [[ ! -d "$WEBRTC_FRAMEWORK" ]]; then
    print -u2 "WebRTC macOS framework not found: $WEBRTC_FRAMEWORK"
    exit 1
fi

DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swiftc \
    "$ROOT/SesoriIntegration.swift" \
    "$ROOT/AndroidEmulator.swift" \
    "$ROOT/AndroidWebRTCStream.swift" \
    "$ROOT/AndroidWebRTCStreamTests.swift" \
    -parse-as-library \
    -swift-version 6 \
    -strict-concurrency=complete \
    -F "$WEBRTC_FRAMEWORK_DIR" \
    -framework WebRTC \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework VideoToolbox \
    -Xlinker -rpath \
    -Xlinker "$WEBRTC_FRAMEWORK_DIR" \
    -sdk "$SDK" \
    -target arm64-apple-macos26.4 \
    -o "$WEBRTC_TESTS"

"$WEBRTC_TESTS"

DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swiftc \
    "$ROOT/DeviceCanvas.swift" \
    "$ROOT/AndroidEmulator.swift" \
    "$ROOT/SesoriIntegration.swift" \
    "$ROOT/AndroidWebRTCStream.swift" \
    -parse-as-library \
    -I "$MODULE_DIR" \
    -F "$FRAMEWORKS" \
    -F "$WEBRTC_FRAMEWORK_DIR" \
    -framework DeviceKit \
    -framework WebRTC \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework VideoToolbox \
    -Xlinker -rpath \
    -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks' \
    -sdk "$SDK" \
    -target arm64-apple-macos26.4 \
    -o "$CONTENTS/MacOS/DeviceCanvas"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
rm -rf "$CONTENTS/Frameworks/WebRTC.framework"
ditto "$WEBRTC_FRAMEWORK" "$CONTENTS/Frameworks/WebRTC.framework"
codesign --force --sign - "$CONTENTS/Frameworks/WebRTC.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

print "$APP"
