# Device Canvas

A freeform workspace for mobile devices, simulators, and emulators.

Device Canvas is an experimental macOS app for arranging multiple live device
screens in one window. It supports booted iOS simulators using Xcode
27's private `DeviceKit.framework` and running Android Studio emulators using
the Android SDK's `adb`. It does not modify Xcode, Device Hub, or Android Studio.

Build with the Xcode 27 beta installed at the default path:

```sh
zsh build.sh
```

Set `XCODE_APP=/path/to/Xcode.app` if Xcode 27 is installed under a name the
script cannot discover.

The build downloads the pinned stasel/WebRTC 151.0.0 XCFramework into the
ignored `.build/dependencies` directory and verifies its SHA-256 digest before
linking. Set `WEBRTC_XCFRAMEWORK_PATH=/path/to/WebRTC.xcframework` to use an
already verified local copy.

Android support looks for `adb` under `ANDROID_SDK_ROOT`, `ANDROID_HOME`, or
Android Studio's default `~/Library/Android/sdk` location. Only running emulator
serials backed by a local Android Studio AVD are included; physical Android
devices and third-party emulators are ignored.

Android display and input use scrcpy 4.1. Install it with Homebrew before
launching Device Canvas:

```sh
brew install scrcpy
```

Launch the host with:

```sh
zsh run.sh
```

The window checks for booted iOS simulators and running Android Studio emulators
every two seconds. Devices appear automatically, and panes disappear when they
shut down unless a Sesori session owns them.

Each pane shows the device name, runtime, and abbreviated identifier. Drag its
title bar to position it anywhere in the window, or drag its lower-right handle
to resize it. Android screens are streamed through scrcpy and decoded by macOS.
Click or drag inside an Android pane to send touch input, scroll normally, and
type after selecting the pane. Right-click sends Back and middle-click sends
Home.

When a Sesori Bridge is running under its default data directory, Device Canvas
connects through the owner-only rendezvous file at
`~/.local/share/sesori/device-canvas/ipc-rendezvous.json`. It publishes the live
device inventory without persisting claim data. Claimed panes show the owning
session, remain visible as offline when a device stops, and provide an action to
open the exact bridge-scoped session in Sesori. Without a compatible Bridge, the
local canvas continues to work normally.

Claimed Android emulators can publish their existing scrcpy video source to a
Sesori WebRTC client. The current remote path is video-only: remote control and
iOS remote video remain unadvertised and fail closed.

For a source-run Bridge using `--data-dir`, launch Device Canvas with
`SESORI_DATA_DIR` set to the same directory.

The implementation relies on private, unsupported Xcode APIs and may require
updates for every Xcode build.
