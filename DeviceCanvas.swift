import AppKit
import DeviceKit
import Foundation
import SwiftUI

private enum DeviceIdentifier: Hashable, Sendable {
    case ios(UUID)
    case android(String)

    init?(stableValue: String) {
        if stableValue.hasPrefix("ios-"),
           let identifier = UUID(uuidString: String(stableValue.dropFirst(4))) {
            self = .ios(identifier)
            return
        }
        if stableValue.hasPrefix("android-") {
            let serial = String(stableValue.dropFirst(8))
            guard !serial.isEmpty else {
                return nil
            }
            self = .android(serial)
            return
        }
        return nil
    }

    var stableValue: String {
        switch self {
        case .ios(let identifier):
            "ios-\(identifier.uuidString)"
        case .android(let serial):
            "android-\(serial)"
        }
    }

    var platform: CanvasPlatform {
        switch self {
        case .ios:
            .ios
        case .android:
            .android
        }
    }
}

private struct DeviceInfo: Identifiable, Equatable, Sendable {
    let id: DeviceIdentifier
    let name: String
    let runtime: String

    var shortIdentifier: String {
        switch id {
        case .ios(let identifier):
            String(identifier.uuidString.prefix(8))
        case .android(let serial):
            serial
        }
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

private enum IOSSimulatorDiscovery {
    private struct Response: Decodable {
        let devices: [String: [DeviceRecord]]
    }

    private struct DeviceRecord: Decodable {
        let name: String
        let udid: String
        let state: String
        let isAvailable: Bool?
    }

    static func bootedSimulators() async throws -> [DeviceInfo] {
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
            var simulatorsByIdentifier: [UUID: DeviceInfo] = [:]

            for (runtimeIdentifier, records) in response.devices
            where runtimeIdentifier.contains(".SimRuntime.iOS-") {
                let runtime = runtimeDisplayName(runtimeIdentifier)

                for record in records
                where record.state == "Booted" && record.isAvailable != false {
                    guard let identifier = UUID(uuidString: record.udid) else {
                        continue
                    }

                    simulatorsByIdentifier[identifier] = DeviceInfo(
                        id: .ios(identifier),
                        name: record.name,
                        runtime: runtime
                    )
                }
            }

            return simulatorsByIdentifier.values.sorted {
                ($0.name, $0.runtime, $0.id.stableValue) < ($1.name, $1.runtime, $1.id.stableValue)
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

    @Published private(set) var devices: [DeviceInfo]
    @Published private(set) var layouts: [DeviceIdentifier: PaneLayout] = [:]
    @Published private(set) var discoveryError: String?
    @Published private(set) var onlineDeviceIdentifiers: Set<DeviceIdentifier>
    @Published private(set) var claimsByDeviceKey: [String: SesoriClaimProjection] = [:]
    @Published private(set) var sesoriStatus = SesoriIntegrationStatus.disconnected

    private var canvasSize = CGSize.zero
    private var highestZIndex = 0.0
    private var nextPlacementIndex = 0
    private var monitoringTask: Task<Void, Never>?
    private var onlineDevicesByIdentifier: [DeviceIdentifier: DeviceInfo]
    private let androidWebRTCService = AndroidWebRTCService()
    private var androidStreamEndpoints: [String: AndroidEmulatorStreamEndpoint] = [:]
    private var registeredAndroidDeviceKeys: Set<String> = []
    private lazy var sesoriIntegration = SesoriIntegrationClient(
        remoteStreams: androidWebRTCService,
        onStatusChanged: { [weak self] status in
            self?.sesoriStatus = status
        },
        onClaimsChanged: { [weak self] claims in
            self?.claimsByDeviceKey = claims
            self?.rebuildPresentedDevices()
        }
    )

    init(initialIdentifiers: [UUID]) {
        let initialDevices = initialIdentifiers.map {
            DeviceInfo(
                id: .ios($0),
                name: "Simulator \(String($0.uuidString.prefix(8)))",
                runtime: "Starting"
            )
        }
        devices = initialDevices
        onlineDeviceIdentifiers = Set(initialDevices.map(\.id))
        onlineDevicesByIdentifier = Dictionary(
            uniqueKeysWithValues: initialDevices.map { ($0.id, $0) }
        )
    }

    func startMonitoring() {
        guard monitoringTask == nil else {
            return
        }

        sesoriIntegration.start()
        publishInventory()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                let existingDevices = self?.onlineDevicesByIdentifier.values.map { $0 } ?? []
                var discovered: [DeviceInfo] = []
                var errors: [String] = []

                do {
                    discovered.append(contentsOf: try await IOSSimulatorDiscovery.bootedSimulators())
                } catch {
                    discovered.append(contentsOf: existingDevices.filter {
                        if case .ios = $0.id { true } else { false }
                    })
                    errors.append(error.localizedDescription)
                }

                do {
                    let androidEmulators = try await AndroidEmulatorDiscovery.runningEmulators()
                    discovered.append(contentsOf: androidEmulators.map {
                        DeviceInfo(
                            id: .android($0.serial),
                            name: $0.name,
                            runtime: $0.runtime
                        )
                    })
                } catch {
                    discovered.append(contentsOf: existingDevices.filter {
                        if case .android = $0.id { true } else { false }
                    })
                    errors.append(error.localizedDescription)
                }

                guard !Task.isCancelled else {
                    return
                }

                self?.reconcile(discovered, errors: errors)

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
        for deviceKey in registeredAndroidDeviceKeys {
            androidWebRTCService.unregisterEndpoint(for: deviceKey)
        }
        registeredAndroidDeviceKeys.removeAll()
        sesoriIntegration.stop()
    }

    func updateCanvasSize(_ size: CGSize) {
        canvasSize = size
        ensureLayouts()
    }

    func layout(for identifier: DeviceIdentifier) -> PaneLayout? {
        layouts[identifier]
    }

    func bringToFront(_ identifier: DeviceIdentifier) {
        guard var layout = layouts[identifier], layout.zIndex < highestZIndex else {
            return
        }

        highestZIndex += 1
        layout.zIndex = highestZIndex
        layouts[identifier] = layout
    }

    func movePane(_ identifier: DeviceIdentifier, to proposedOrigin: CGPoint) {
        guard var layout = layouts[identifier] else {
            return
        }

        layout.origin = clampedOrigin(proposedOrigin, paneSize: layout.size)
        layouts[identifier] = layout
    }

    func resizePane(_ identifier: DeviceIdentifier, to proposedSize: CGSize) {
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

    func isOnline(_ identifier: DeviceIdentifier) -> Bool {
        onlineDeviceIdentifiers.contains(identifier)
    }

    func claim(for identifier: DeviceIdentifier) -> SesoriClaimProjection? {
        claimsByDeviceKey[identifier.stableValue]
    }

    func androidStreamEndpoint(for identifier: DeviceIdentifier) -> AndroidEmulatorStreamEndpoint? {
        guard case .android(let serial) = identifier else {
            return nil
        }
        return androidStreamEndpoints[serial]
    }

    func openSesoriSession(_ claim: SesoriClaimProjection) {
        guard let url = SesoriSessionLinkBuilder.url(for: claim) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func reconcile(_ discovered: [DeviceInfo], errors: [String]) {
        var updatedOnlineDevices: [DeviceIdentifier: DeviceInfo] = [:]
        for device in discovered {
            updatedOnlineDevices[device.id] = device
        }
        reconcileAndroidStreamEndpoints(with: updatedOnlineDevices)
        onlineDevicesByIdentifier = updatedOnlineDevices
        onlineDeviceIdentifiers = Set(updatedOnlineDevices.keys)
        discoveryError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        rebuildPresentedDevices()
        publishInventory()
    }

    private func rebuildPresentedDevices() {
        var remainingOnline = onlineDevicesByIdentifier
        var updated: [DeviceInfo] = []
        var includedIdentifiers: Set<DeviceIdentifier> = []

        for device in devices {
            if let online = remainingOnline.removeValue(forKey: device.id) {
                updated.append(online)
                includedIdentifiers.insert(device.id)
            } else if claimsByDeviceKey[device.id.stableValue] != nil {
                updated.append(device)
                includedIdentifiers.insert(device.id)
            }
        }

        let newOnlineDevices = remainingOnline.values.sorted {
            ($0.name, $0.runtime, $0.id.stableValue) < ($1.name, $1.runtime, $1.id.stableValue)
        }
        updated.append(contentsOf: newOnlineDevices)
        includedIdentifiers.formUnion(newOnlineDevices.map(\.id))

        for claim in claimsByDeviceKey.values.sorted(by: { $0.deviceKey < $1.deviceKey }) {
            guard let identifier = DeviceIdentifier(stableValue: claim.deviceKey),
                  !includedIdentifiers.contains(identifier) else {
                continue
            }
            updated.append(Self.offlinePlaceholder(for: identifier))
            includedIdentifiers.insert(identifier)
        }

        devices = updated
        ensureLayouts()
    }

    private func publishInventory() {
        let inventory = onlineDevicesByIdentifier.values
            .sorted { $0.id.stableValue < $1.id.stableValue }
            .map { device in
                CanvasDeviceDescriptor(
                    deviceKey: device.id.stableValue,
                    platform: device.id.platform,
                    displayName: device.name,
                    runtimeDescription: device.runtime,
                    modelDescription: device.name,
                    dimensions: nil,
                    orientation: nil,
                    capabilities: device.id.platform == .android
                        ? androidWebRTCService.capabilities
                        : .localPresentation
                )
            }
        sesoriIntegration.updateInventory(inventory)
    }

    private func reconcileAndroidStreamEndpoints(
        with onlineDevices: [DeviceIdentifier: DeviceInfo]
    ) {
        let onlineAndroidDevices = onlineDevices.keys.compactMap { identifier -> (String, String)? in
            guard case .android(let serial) = identifier else {
                return nil
            }
            return (serial, identifier.stableValue)
        }
        let onlineDeviceKeys = Set(onlineAndroidDevices.map(\.1))

        for (serial, deviceKey) in onlineAndroidDevices {
            let endpoint: AndroidEmulatorStreamEndpoint
            if let existing = androidStreamEndpoints[serial] {
                endpoint = existing
            } else {
                endpoint = AndroidEmulatorStreamEndpoint(serial: serial)
                androidStreamEndpoints[serial] = endpoint
            }
            if !registeredAndroidDeviceKeys.contains(deviceKey) {
                androidWebRTCService.register(endpoint: endpoint, for: deviceKey)
            }
        }

        for deviceKey in registeredAndroidDeviceKeys.subtracting(onlineDeviceKeys) {
            androidWebRTCService.unregisterEndpoint(for: deviceKey)
        }
        registeredAndroidDeviceKeys = onlineDeviceKeys
    }

    private static func offlinePlaceholder(for identifier: DeviceIdentifier) -> DeviceInfo {
        switch identifier {
        case .ios(let identifier):
            DeviceInfo(
                id: .ios(identifier),
                name: "iOS Simulator",
                runtime: "Offline"
            )
        case .android(let serial):
            DeviceInfo(
                id: .android(serial),
                name: "Android Emulator",
                runtime: "Offline"
            )
        }
    }

    private func ensureLayouts() {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return
        }

        let margin = 24.0
        let spacing = 24.0
        let paneCount = max(devices.count, 1)
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

        for device in devices where layouts[device.id] == nil {
            let column = nextPlacementIndex % columns
            let row = nextPlacementIndex / columns
            let proposedOrigin = CGPoint(
                x: gridOriginX + CGFloat(column) * (paneWidth + spacing),
                y: margin + CGFloat(row) * (paneHeight + spacing)
            )

            highestZIndex += 1
            layouts[device.id] = PaneLayout(
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

private struct DeviceWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)

                if model.devices.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(model.devices) { device in
                    if let layout = model.layout(for: device.id) {
                        DevicePane(
                            device: device,
                            layout: layout,
                            isOnline: model.isOnline(device.id),
                            claim: model.claim(for: device.id),
                            sesoriStatus: model.sesoriStatus,
                            androidStreamEndpoint: model.androidStreamEndpoint(for: device.id),
                            onActivate: { model.bringToFront(device.id) },
                            onMove: { model.movePane(device.id, to: $0) },
                            onResize: { model.resizePane(device.id, to: $0) },
                            onOpenSesoriSession: { claim in
                                model.openSesoriSession(claim)
                            }
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
            Text("Start a simulator or emulator")
                .font(.title3.weight(.semibold))
            Text("Booted iOS simulators and Android Studio emulators appear here automatically.")
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

    @State private var naturalSize: CGSize = .zero

    var body: some View {
        GeometryReader { container in
            let widthScale = naturalSize.width > 0 ? container.size.width / naturalSize.width : 1
            let heightScale = naturalSize.height > 0 ? container.size.height / naturalSize.height : 1

            // DeviceKit 27 renders at its intrinsic size, including the bezel.
            // Constraining it to an estimated phone aspect ratio crops the screen.
            // Measure before scaling so resizing and rotation preserve the full view.
            DeviceView(deviceIdentifier: deviceIdentifier)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    naturalSize = size
                }
                .scaleEffect(min(widthScale, heightScale))
                .frame(width: container.size.width, height: container.size.height)
        }
    }
}

private struct DevicePane: View {
    let device: DeviceInfo
    let layout: PaneLayout
    let isOnline: Bool
    let claim: SesoriClaimProjection?
    let sesoriStatus: SesoriIntegrationStatus
    let androidStreamEndpoint: AndroidEmulatorStreamEndpoint?
    let onActivate: () -> Void
    let onMove: (CGPoint) -> Void
    let onResize: (CGSize) -> Void
    let onOpenSesoriSession: (SesoriClaimProjection) -> Void

    @GestureState private var moveTranslation = CGSize.zero
    @GestureState private var resizeTranslation = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .fixedSize(horizontal: false, vertical: true)
                .zIndex(1)

            sesoriBar
                .fixedSize(horizontal: false, vertical: true)
                .zIndex(1)

            ZStack {
                Color.black.opacity(0.22)

                deviceScreen
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

    @ViewBuilder
    private var deviceScreen: some View {
        if isOnline {
            switch device.id {
            case .ios(let identifier):
                ScaledDeviceView(deviceIdentifier: identifier)
            case .android(let serial):
                AndroidEmulatorView(serial: serial, frameSink: androidStreamEndpoint)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "powerplug")
                    .font(.system(size: 34, weight: .light))
                Text("Device offline")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? .green : .secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(device.runtime) - \(isOnline ? "Online" : "Offline") - \(device.shortIdentifier)")
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
        .accessibilityLabel("Move \(device.name), \(isOnline ? "online" : "offline")")
        .accessibilityIdentifier("pane-title-\(device.id.stableValue)")
    }

    @ViewBuilder
    private var sesoriBar: some View {
        HStack(spacing: 8) {
            switch sesoriStatus {
            case .connected:
                if let claim {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.indigo)
                    Text(claim.ownerDisplayTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button {
                        onOpenSesoriSession(claim)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.indigo.opacity(0.13), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(claim.ownerDisplayTitle) in Sesori")
                    .accessibilityLabel("Open \(claim.ownerDisplayTitle) in Sesori")
                    .accessibilityIdentifier("open-sesori-\(device.id.stableValue)")
                } else {
                    Image(systemName: "circle.dashed")
                    Text("Unclaimed in Sesori")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                Text("Syncing with Sesori")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            case .incompatible:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Sesori update required")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            case .disconnected:
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(.secondary)
                Text("Sesori disconnected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sesori-claim-\(device.id.stableValue)")
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
            .accessibilityLabel("Resize \(device.name)")
            .accessibilityIdentifier("pane-resize-\(device.id.stableValue)")
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
        window.contentView = NSHostingView(rootView: DeviceWorkspaceView(model: workspaceModel))
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
