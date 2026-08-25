# Device Hub 27 reverse-engineering notes

## Examined build

- Xcode: `27.0 beta 5` (`27A5237l`)
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

## Remote transport feasibility

Validated on 2026-08-25 for the Sesori remote-simulator entry gate. These are
capture/control architecture findings, not production streaming code.

### Android

The existing scrcpy 4.1 connection exposes Annex-B H.264 to
`AndroidEmulatorStream` before `H264AnnexBParser` builds sample buffers for the
local `AVSampleBufferDisplayLayer`. A Pixel 10 Pro Android 17 workload produced
210 constrained-baseline frames over 25.57 seconds, including rotation between
`716x1600` and `1600x716`, at about 739 kbit/s. The mostly static workload was
VFR at 8.21 frames/s and is not an active-content frame-rate target.

The reviewed WebRTC ObjC framework exposes decoded-frame injection through
`RTCVideoSource`, `RTCVideoCapturer`, and `RTCCVPixelBuffer`. It has no stable
public encoded-H.264 track injection API. The candidate architecture is:

1. Keep the current compressed sample path for local display.
2. Decode the same access units with VideoToolbox to `CVPixelBuffer`.
3. Stamp frames from one monotonic host clock because the current scrcpy session
   disables frame metadata.
4. Feed decoded frames to WebRTC for H.264 re-encode.

For the 210-frame source, H.264 copy completed in 0.07 seconds, VideoToolbox
decode in 0.36 seconds, and decode plus VideoToolbox re-encode in 0.77 seconds.
The wall-clock total is about 273 source frames/s and reached 127.7 MiB peak RSS.
During a separate real-time file re-encode and repeated input, the production
local renderer remained connected; Device Canvas averaged 14.8% of one host
core, peaked at 35.6%, and held 56.6-58.1 MiB RSS. That re-encode wrote to
`/dev/null`; it was not one live scrcpy source feeding both local display and
WebRTC, so it is a coexistence baseline rather than an integrated-path result.

The Device Canvas WebRTC candidate is `stasel/WebRTC 151.0.0`. Its universal
macOS slice compiled and ran on the release host, its archive includes iOS device
and simulator slices, it carries the upstream WebRTC BSD-3 license, and it has a
27.1 MiB universal macOS binary. The Flutter peer candidate is
`flutter_webrtc 1.6.0`, which currently pins WebRTC `144.7559.09`. Production
must pin exact versions and retain binary notices.

### iOS simulator frames

The remote source should not depend on DeviceKit's framebuffer-provider symbols.
DeviceKit is absent from Xcode 26.6, and the Xcode 27 beta 5 providers remain
symbol-only evidence without a raw-frame callback in the current shim.

Private `SimulatorKit.SimDeviceScreen` is callable under both tested toolchains.
Registering for rendering events and retaining the registration exposes
`unmaskedSurface` as a CPU-readable BGRA IOSurface:

| Toolchain | Framework location | Surface | Rendering callbacks |
|---|---|---|---|
| Xcode 26.6 (`17F113`) | `Developer/Library/PrivateFrameworks` | `1206x2622`, scale 3, 4864 bytes/row | 302 over 5.019 seconds, 59.97/s |
| Xcode 27 beta 5 (`27A5237l`) | `Contents/SharedFrameworks` | `1206x2622`, scale 3, 4864 bytes/row | 302 over 5.022 seconds, 59.93/s |

Locking and sampling the IOSurface succeeded, and checksums changed while a
UIKit probe animated. The compile-time SimulatorKit shim must use
`-enable-library-evolution`; without it, private ABI dispatch was incorrect.

Public `simctl io screenshot` averaged 444 ms under Xcode 26.6 and 367 ms under
Xcode 27 beta 5, so screenshots are not an interactive stream source. Public
`simctl io recordVideo --codec=h264` produced about 60 frames/s and is an encoded
fallback, but its recorder lifecycle is not the selected low-latency raw source.

### iOS simulator input

The callable input seam is the private DTUHID XPC service:

```text
com.apple.coredevice.feature.remote.hid.digitizer
```

The probe obtained the service Mach port from CoreSimulator, created the private
XPC endpoint with `xpc_endpoint_create_mach_port_4sim`, and enabled the simulator
connection with `xpc_connection_enable_sim2host_4sim`. Under both Xcode 26.6 and
Xcode 27 beta 5:

- `IndigoDigitizerEvent` down/up messages activated a UIKit button;
- `IndigoKeyboardButtonEvent` messages using USB usage 4 entered `a` into the
  focused text field;
- screenshots confirmed the changed touch count and text value.

`SimDeviceLegacyHIDClient` acknowledged probe messages but did not affect UIKit,
so it is not the selected path. There is no supported public `simctl` touch or
text-injection command.

### Decision

The component probes support the proposed Android decode/re-encode architecture,
but production integration remains a NO-GO until one real scrcpy source feeds
both local display and WebRTC and meets capture-to-display, input-to-visible,
resource, and lifecycle targets.

The iOS probes establish short-run raw SimulatorKit frames, one DTUHID touch, and
one USB keyboard usage under the recorded matrix. They do not yet establish
sustained stability across rotation/restart, repeated touch and keyboard variants,
drag/multitouch, coordinate mapping, general text, acceptable interaction latency,
production signing, or fail-closed ABI containment, so iOS remote capability
remains unavailable. A change to either private iOS seam must remove the
advertised remote capability without affecting local DeviceKit presentation,
Android transport, or Sesori ownership.
