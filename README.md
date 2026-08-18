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
shut down.

Each pane shows the device name, runtime, and abbreviated identifier. Drag its
title bar to position it anywhere in the window, or drag its lower-right handle
to resize it. Android screens are streamed through scrcpy and decoded by macOS.
Click or drag inside an Android pane to send touch input, scroll normally, and
type after selecting the pane. Right-click sends Back and middle-click sends
Home.

The implementation relies on private, unsupported Xcode APIs and may require
updates for every Xcode build.
