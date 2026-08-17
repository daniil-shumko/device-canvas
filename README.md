# Device Hub Tiler experiment

This project tests whether Xcode 27's private `DeviceKit.framework` can render
multiple interactive simulator views side by side in one macOS window. It does
not modify Xcode or Device Hub.

Build with the Xcode 27 beta installed at the default path:

```sh
zsh build.sh
```

Set `XCODE_APP=/path/to/Xcode.app` if Xcode 27 is installed under a name the
script cannot discover.

Launch the host with:

```sh
zsh run.sh
```

The window checks for booted iOS simulators every two seconds. Simulators opened
in Device Hub appear automatically, and panes disappear when their simulators
shut down.

Each pane shows the simulator name, runtime, and abbreviated UDID. Drag its
title bar to position it anywhere in the window, or drag its lower-right handle
to resize it.

The implementation relies on private, unsupported Xcode APIs and may require
updates for every Xcode build.
