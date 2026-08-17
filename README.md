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

Boot at least two iOS simulators, then launch all booted iOS simulators with:

```sh
zsh run.sh
```

To choose specific simulators, pass two or more UDIDs:

```sh
zsh run.sh \
  A9D7B15B-BD4D-4EB3-A847-DED87DEE35C4 \
  20A4F6B7-04E3-43CB-918D-23269FE26217
```

The implementation relies on private, unsupported Xcode APIs and may require
updates for every Xcode build.
