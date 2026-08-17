import AppKit
import DeviceKit
import Foundation
import SwiftUI

private struct TiledDeviceViews: View {
    let deviceIdentifiers: [UUID]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(deviceIdentifiers, id: \.self) { deviceIdentifier in
                DeviceView(deviceIdentifier: deviceIdentifier)
                    .aspectRatio(contentMode: .fit)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(minWidth: CGFloat(deviceIdentifiers.count) * 300, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let deviceIdentifiers: [UUID]
    private var window: NSWindow?

    init(deviceIdentifiers: [UUID]) {
        self.deviceIdentifiers = deviceIdentifiers
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visibleSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(max(CGFloat(deviceIdentifiers.count) * 420 + 24, 640), visibleSize.width * 0.9)
        let height = min(max(720, visibleSize.height * 0.85), visibleSize.height * 0.9)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Device Hub Tiler"
        window.contentMinSize = NSSize(width: CGFloat(deviceIdentifiers.count) * 300, height: 600)
        window.contentView = NSHostingView(rootView: TiledDeviceViews(deviceIdentifiers: deviceIdentifiers))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
private enum DeviceHubTiler {
    @MainActor
    static func main() {
        let deviceIdentifiers = CommandLine.arguments.dropFirst().compactMap(UUID.init(uuidString:))

        guard deviceIdentifiers.count >= 2 else {
            fputs("usage: DeviceHubTiler <simulator-udid> <simulator-udid> [...]\n", stderr)
            exit(64)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(deviceIdentifiers: deviceIdentifiers)
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
