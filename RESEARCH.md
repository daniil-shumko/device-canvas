# Device Hub 27 reverse-engineering notes

## Examined build

- Xcode: `27.0 beta 5` (`27A5237d`)
- Device Hub: `27.0` (`255.114`)
- Device Hub bundle: `Contents/Applications/DeviceHub.app`
- DeviceKit: `Contents/SharedFrameworks/DeviceKit.framework`, version `255`
- Host OS used for validation: macOS `26.6.1`

`DeviceHub.app` declares `DevicesTrampoline` as its bundle executable. The
trampoline launches the second `arm64e` executable at
`Contents/MacOS/DeviceHub`. Most of the UI and all live-device presentation
code is in the 12 MB `DeviceKit` private framework, not in the app executable.

## Window architecture

Swift metadata and exported symbols identify the relevant types:

- `DeviceManagementWindow()` creates the SwiftUI scenes.
- `DeviceWindowRequest` carries one device request into a window scene.
- `DeviceViewWindowContainer` hosts that request.
- `DeviceWindowSizingLayout` sizes a single device view.
- `WindowService` tracks `deviceWindows`, `managementWindows`, and
  `managementWindowSelections`.
- `DeviceView.init(deviceIdentifier:)` is an exported SwiftUI view initializer.

DeviceKit contains commands and strings for `New Tab`, `New Window`, `Open in
New Tab`, and `Open in New Window`. Its tab implementation calls AppKit's
`addTabbedWindow:ordered:`. There is no tile command, split container, tile
preference, or second layout that combines device windows.

The persisted preference
`NSWindowTabbingShoudShowTabBarKey-SwiftUI-WindowGroup-com.apple.dt.DeviceKit.DeviceManagementWindow`
also confirms that the tabs are native AppKit window tabs. `NSWindowTabGroup`
only exposes one `selectedWindow`; non-selected tab content is not presented.
It has no API for displaying multiple members simultaneously.

## Feasibility result

Patching Device Hub's tab group is not a practical implementation. It would
require moving independent SwiftUI scene roots into a new split-view hierarchy,
and modifying either Device Hub or DeviceKit would invalidate Apple's code
signature and library-validation assumptions.

A separate host is practical because `DeviceView` is exported. The prototype
in this repository creates one `DeviceView` for each supplied simulator UDID
inside a single `HStack`, while loading the original, unmodified DeviceKit.

Runtime validation with two booted iOS simulators showed:

- The `SimulatorDeviceKitPlugin` loaded successfully.
- Both simulator framebuffer providers reached `Active` concurrently.
- A separate `DefaultHIDViewProvider` connected for each simulator.
- Both complete live device frames rendered side by side in one window.
- The host ran ad hoc signed and without Device Hub's Apple-private
  entitlements.

## Limitations

- DeviceKit is private and version-locked. Apple can change its ABI at any
  time, including between Xcode betas.
- Apple omits `DeviceKit.swiftmodule`; `DeviceKitShim.swift` supplies only the
  compile-time declaration used by this prototype. Its implementation is never
  linked.
- Simulator display and HID setup were validated. Physical-device presentation
  was not, and some physical-device operations are entitlement-gated.
- This host presents the live devices only. Device Hub's management sidebar,
  inspectors, and app-wide menus are not duplicated.
- Device Hub tabs cannot be transferred into this window. Supply the same
  simulator UDIDs to the host instead.
