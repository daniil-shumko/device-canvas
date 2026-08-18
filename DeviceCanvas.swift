import AppKit
import DeviceKit
import Foundation
import SwiftUI

private struct SimulatorInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let runtime: String

    var shortIdentifier: String {
        String(id.uuidString.prefix(8))
    }
}

private struct PaneLayout: Equatable {
    var origin: CGPoint
    var size: CGSize
    var zIndex: Double
}

private enum SimulatorDiscoveryError: LocalizedError {
    case commandFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status):
            "simctl exited with status \(status)"
        }
    }
}

private enum SimulatorDiscovery {
    private struct Response: Decodable {
        let devices: [String: [DeviceRecord]]
    }

    private struct DeviceRecord: Decodable {
        let name: String
        let udid: String
        let state: String
        let isAvailable: Bool?
    }

    static func bootedIOSSimulators() async throws -> [SimulatorInfo] {
        let developerDirectory = deviceKitDeveloperDirectory

        return try await Task.detached(priority: .utility) {
            let process = Process()
            let standardOutput = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "list", "devices", "booted", "--json"]
            process.standardOutput = standardOutput
            process.standardError = FileHandle.nullDevice

            if let developerDirectory {
                var environment = ProcessInfo.processInfo.environment
                environment["DEVELOPER_DIR"] = developerDirectory
                process.environment = environment
            }

            try process.run()
            let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw SimulatorDiscoveryError.commandFailed(process.terminationStatus)
            }

            let response = try JSONDecoder().decode(Response.self, from: data)
            var simulatorsByIdentifier: [UUID: SimulatorInfo] = [:]

            for (runtimeIdentifier, records) in response.devices
            where runtimeIdentifier.contains(".SimRuntime.iOS-") {
                let runtime = runtimeDisplayName(runtimeIdentifier)

                for record in records
                where record.state == "Booted" && record.isAvailable != false {
                    guard let identifier = UUID(uuidString: record.udid) else {
                        continue
                    }

                    simulatorsByIdentifier[identifier] = SimulatorInfo(
                        id: identifier,
                        name: record.name,
                        runtime: runtime
                    )
                }
            }

            return simulatorsByIdentifier.values.sorted {
                ($0.name, $0.runtime, $0.id.uuidString) < ($1.name, $1.runtime, $1.id.uuidString)
            }
        }.value
    }

    private static let deviceKitDeveloperDirectory: String? = {
        guard let frameworkURL = Bundle(identifier: "com.apple.dt.DeviceKit")?.bundleURL else {
            return nil
        }

        return frameworkURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Developer", isDirectory: true)
            .path
    }()

    private static func runtimeDisplayName(_ identifier: String) -> String {
        guard let runtime = identifier.components(separatedBy: ".SimRuntime.").last else {
            return identifier
        }

        let components = runtime.split(separator: "-")
        guard let platform = components.first, components.count > 1 else {
            return runtime
        }

        return "\(platform) \(components.dropFirst().joined(separator: "."))"
    }
}

@MainActor
private final class WorkspaceModel: ObservableObject {
    static let minimumPaneSize = CGSize(width: 240, height: 360)

    @Published private(set) var simulators: [SimulatorInfo]
    @Published private(set) var layouts: [UUID: PaneLayout] = [:]
    @Published private(set) var discoveryError: String?

    private var canvasSize = CGSize.zero
    private var highestZIndex = 0.0
    private var nextPlacementIndex = 0
    private var monitoringTask: Task<Void, Never>?

    init(initialIdentifiers: [UUID]) {
        simulators = initialIdentifiers.map {
            SimulatorInfo(id: $0, name: "Simulator \(String($0.uuidString.prefix(8)))", runtime: "Starting")
        }
    }

    func startMonitoring() {
        guard monitoringTask == nil else {
            return
        }

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let discovered = try await SimulatorDiscovery.bootedIOSSimulators()
                    guard !Task.isCancelled else {
                        return
                    }

                    self?.reconcile(discovered)
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }

                    self?.discoveryError = error.localizedDescription
                }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func updateCanvasSize(_ size: CGSize) {
        canvasSize = size
        ensureLayouts()
    }

    func layout(for identifier: UUID) -> PaneLayout? {
        layouts[identifier]
    }

    func bringToFront(_ identifier: UUID) {
        guard var layout = layouts[identifier], layout.zIndex < highestZIndex else {
            return
        }

        highestZIndex += 1
        layout.zIndex = highestZIndex
        layouts[identifier] = layout
    }

    func movePane(_ identifier: UUID, to proposedOrigin: CGPoint) {
        guard var layout = layouts[identifier] else {
            return
        }

        layout.origin = clampedOrigin(proposedOrigin, paneSize: layout.size)
        layouts[identifier] = layout
    }

    func resizePane(_ identifier: UUID, to proposedSize: CGSize) {
        guard var layout = layouts[identifier] else {
            return
        }

        let maximumWidth = max(Self.minimumPaneSize.width, canvasSize.width - layout.origin.x - 12)
        let maximumHeight = max(Self.minimumPaneSize.height, canvasSize.height - layout.origin.y - 12)
        layout.size = CGSize(
            width: min(max(proposedSize.width, Self.minimumPaneSize.width), maximumWidth),
            height: min(max(proposedSize.height, Self.minimumPaneSize.height), maximumHeight)
        )
        layouts[identifier] = layout
    }

    private func reconcile(_ discovered: [SimulatorInfo]) {
        var remaining = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        var updated = simulators.compactMap { remaining.removeValue(forKey: $0.id) }
        updated.append(contentsOf: remaining.values.sorted {
            ($0.name, $0.runtime, $0.id.uuidString) < ($1.name, $1.runtime, $1.id.uuidString)
        })

        simulators = updated
        discoveryError = nil
        ensureLayouts()
    }

    private func ensureLayouts() {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return
        }

        let margin = 24.0
        let spacing = 24.0
        let paneCount = max(simulators.count, 1)
        let maximumColumns = max(
            1,
            Int((canvasSize.width - margin * 2 + spacing) / (Self.minimumPaneSize.width + spacing))
        )
        let columns = min(paneCount, maximumColumns)
        let rows = Int(ceil(Double(paneCount) / Double(columns)))
        let availableWidth = canvasSize.width - margin * 2 - CGFloat(columns - 1) * spacing
        let availableHeight = canvasSize.height - margin * 2 - CGFloat(rows - 1) * spacing
        let paneWidth = min(340, max(Self.minimumPaneSize.width, availableWidth / CGFloat(columns)))
        let paneHeight = min(760, max(Self.minimumPaneSize.height, availableHeight / CGFloat(rows)))
        let paneSize = CGSize(width: paneWidth, height: paneHeight)
        let gridWidth = CGFloat(columns) * paneWidth + CGFloat(columns - 1) * spacing
        let gridOriginX = max(margin, (canvasSize.width - gridWidth) / 2)

        for simulator in simulators where layouts[simulator.id] == nil {
            let column = nextPlacementIndex % columns
            let row = nextPlacementIndex / columns
            let proposedOrigin = CGPoint(
                x: gridOriginX + CGFloat(column) * (paneWidth + spacing),
                y: margin + CGFloat(row) * (paneHeight + spacing)
            )

            highestZIndex += 1
            layouts[simulator.id] = PaneLayout(
                origin: clampedOrigin(proposedOrigin, paneSize: paneSize),
                size: paneSize,
                zIndex: highestZIndex
            )
            nextPlacementIndex += 1
        }
    }

    private func clampedOrigin(_ origin: CGPoint, paneSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(0, origin.x), max(0, canvasSize.width - paneSize.width)),
            y: min(max(0, origin.y), max(0, canvasSize.height - paneSize.height))
        )
    }
}

private struct SimulatorWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)

                if model.simulators.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(model.simulators) { simulator in
                    if let layout = model.layout(for: simulator.id) {
                        SimulatorPane(
                            simulator: simulator,
                            layout: layout,
                            onActivate: { model.bringToFront(simulator.id) },
                            onMove: { model.movePane(simulator.id, to: $0) },
                            onResize: { model.resizePane(simulator.id, to: $0) }
                        )
                        .offset(x: layout.origin.x, y: layout.origin.y)
                        .zIndex(layout.zIndex)
                    }
                }
            }
            .coordinateSpace(name: "workspace")
            .clipped()
            .onChange(of: geometry.size, initial: true) { _, size in
                model.updateCanvasSize(size)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start an iOS simulator in Device Hub")
                .font(.title3.weight(.semibold))
            Text("Booted simulators appear here automatically.")
                .foregroundStyle(.secondary)

            if let discoveryError = model.discoveryError {
                Text(discoveryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

private struct ScaledDeviceView: View {
    let deviceIdentifier: UUID

    @State private var referenceSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            let sourceSize = referenceSize ?? geometry.size
            let widthScale = sourceSize.width > 0 ? geometry.size.width / sourceSize.width : 1
            let heightScale = sourceSize.height > 0 ? geometry.size.height / sourceSize.height : 1

            DeviceView(deviceIdentifier: deviceIdentifier)
                .aspectRatio(contentMode: .fit)
                .frame(width: sourceSize.width, height: sourceSize.height)
                .scaleEffect(min(widthScale, heightScale))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onChange(of: geometry.size, initial: true) { _, size in
                    guard referenceSize == nil, size.width > 0, size.height > 0 else {
                        return
                    }

                    referenceSize = size
                }
        }
    }
}

private struct SimulatorPane: View {
    let simulator: SimulatorInfo
    let layout: PaneLayout
    let onActivate: () -> Void
    let onMove: (CGPoint) -> Void
    let onResize: (CGSize) -> Void

    @GestureState private var moveTranslation = CGSize.zero
    @GestureState private var resizeTranslation = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .fixedSize(horizontal: false, vertical: true)
                .zIndex(1)

            ZStack {
                Color.black.opacity(0.22)

                ScaledDeviceView(deviceIdentifier: simulator.id)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: liveSize.width, height: liveSize.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
        .offset(x: moveTranslation.width, y: moveTranslation.height)
    }

    private var liveSize: CGSize {
        CGSize(
            width: max(WorkspaceModel.minimumPaneSize.width, layout.size.width + resizeTranslation.width),
            height: max(WorkspaceModel.minimumPaneSize.height, layout.size.height + resizeTranslation.height)
        )
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(simulator.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(simulator.runtime) - \(simulator.shortIdentifier)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "move.3d")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(0.055))
        .gesture(moveGesture)
        .help("Drag to move")
        .accessibilityLabel("Move \(simulator.name)")
        .accessibilityIdentifier("pane-title-\(simulator.id.uuidString)")
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .padding(6)
            .gesture(resizeGesture)
            .help("Drag to resize")
            .accessibilityLabel("Resize \(simulator.name)")
            .accessibilityIdentifier("pane-resize-\(simulator.id.uuidString)")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
            .updating($moveTranslation) { value, translation, _ in
                translation = value.translation
            }
            .onEnded { value in
                onActivate()
                onMove(
                    CGPoint(
                        x: layout.origin.x + value.translation.width,
                        y: layout.origin.y + value.translation.height
                    )
                )
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
            .updating($resizeTranslation) { value, translation, _ in
                translation = value.translation
            }
            .onEnded { value in
                onActivate()
                onResize(
                    CGSize(
                        width: layout.size.width + value.translation.width,
                        height: layout.size.height + value.translation.height
                    )
                )
            }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let workspaceModel: WorkspaceModel
    private var window: NSWindow?

    init(initialIdentifiers: [UUID]) {
        workspaceModel = WorkspaceModel(initialIdentifiers: initialIdentifiers)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visibleSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(1280, visibleSize.width * 0.9)
        let height = min(max(720, visibleSize.height * 0.85), visibleSize.height * 0.9)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Device Canvas"
        window.contentMinSize = NSSize(width: 700, height: 500)
        window.contentView = NSHostingView(rootView: SimulatorWorkspaceView(model: workspaceModel))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        workspaceModel.startMonitoring()
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceModel.stopMonitoring()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
private enum DeviceCanvas {
    @MainActor
    static func main() {
        let initialIdentifiers = CommandLine.arguments.dropFirst().compactMap(UUID.init(uuidString:))
        let app = NSApplication.shared
        let delegate = AppDelegate(initialIdentifiers: initialIdentifiers)
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
