import Darwin
import Foundation

let sesoriDeviceCanvasProtocolVersion = 2

private enum SesoriProtocolLimits {
    static let maximumFrameByteCount = 1_048_576
    static let maximumInventoryDevices = 64
    static let maximumIdentifierLength = 512
    static let maximumDisplayLength = 512
    static let maximumDimension = 32_768
}

enum SesoriIntegrationStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case incompatible
}

enum CanvasPlatform: String, Codable, Sendable {
    case ios
    case android
}

enum CanvasOrientation: String, Codable, Sendable {
    case portrait
    case landscape
}

struct CanvasDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int

    var isValid: Bool {
        width > 0 && height > 0
            && width <= SesoriProtocolLimits.maximumDimension
            && height <= SesoriProtocolLimits.maximumDimension
    }
}

struct CanvasCapabilities: Codable, Equatable, Sendable {
    let localView: Bool
    let remoteVideo: Bool
    let remoteControl: Bool
    let input: Bool

    static let localPresentation = CanvasCapabilities(
        localView: true,
        remoteVideo: false,
        remoteControl: false,
        input: true
    )
}

struct CanvasDeviceDescriptor: Codable, Equatable, Sendable {
    let deviceKey: String
    let platform: CanvasPlatform
    let displayName: String
    let runtimeDescription: String
    let modelDescription: String
    let dimensions: CanvasDimensions?
    let orientation: CanvasOrientation?
    let capabilities: CanvasCapabilities

    var isValid: Bool {
        !deviceKey.isEmpty &&
            deviceKey.count <= SesoriProtocolLimits.maximumIdentifierLength &&
            !displayName.isEmpty &&
            displayName.count <= SesoriProtocolLimits.maximumDisplayLength &&
            !runtimeDescription.isEmpty &&
            runtimeDescription.count <= SesoriProtocolLimits.maximumDisplayLength &&
            !modelDescription.isEmpty &&
            modelDescription.count <= SesoriProtocolLimits.maximumDisplayLength &&
            (dimensions?.isValid ?? true)
    }
}

struct SesoriClaimProjection: Codable, Equatable, Sendable {
    let bridgeId: String
    let sessionId: String
    let deviceKey: String
    let revision: Int
    let displayTitle: String?

    var ownerDisplayTitle: String {
        guard let displayTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayTitle.isEmpty else {
            return "Sesori session"
        }
        return displayTitle
    }

    func validated() throws -> Self {
        guard !bridgeId.isEmpty,
              bridgeId.count <= SesoriProtocolLimits.maximumIdentifierLength,
              !sessionId.isEmpty,
              sessionId.count <= SesoriProtocolLimits.maximumIdentifierLength,
              !deviceKey.isEmpty,
              deviceKey.count <= SesoriProtocolLimits.maximumIdentifierLength,
              (displayTitle?.count ?? 0) <= SesoriProtocolLimits.maximumDisplayLength,
              revision > 0 else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return self
    }
}

struct SesoriRendezvous: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let port: Int
    let bearerSecret: String
    let bridgeId: String
    let processGeneration: String

    func validated() throws -> Self {
        guard protocolVersion == sesoriDeviceCanvasProtocolVersion else {
            throw SesoriIntegrationError.unsupportedProtocolVersion
        }
        guard (1...65_535).contains(port),
              !bearerSecret.isEmpty,
              !bridgeId.isEmpty,
              !processGeneration.isEmpty else {
            throw SesoriIntegrationError.invalidRendezvous
        }
        return self
    }
}

enum SesoriIPCMessage: Equatable, Sendable {
    case helloAccepted(protocolVersion: Int, bridgeId: String)
    case claimsSnapshot([SesoriClaimProjection])
    case claimUpdated(SesoriClaimProjection)
    case claimRemoved(bridgeId: String, deviceKey: String, revision: Int)
    case compatibilityStatus(supported: Bool, protocolVersion: Int, reason: String)
}

enum SesoriIntegrationError: LocalizedError {
    case insecureRendezvous
    case invalidRendezvous
    case unsupportedProtocolVersion
    case invalidProtocolMessage
    case unexpectedProtocolMessage

    var errorDescription: String? {
        switch self {
        case .insecureRendezvous:
            "Sesori rendezvous permissions are not owner-only"
        case .invalidRendezvous:
            "Sesori rendezvous is invalid"
        case .unsupportedProtocolVersion:
            "Sesori Device Canvas protocol is unsupported"
        case .invalidProtocolMessage:
            "Sesori Device Canvas message is invalid"
        case .unexpectedProtocolMessage:
            "Sesori Device Canvas message arrived out of order"
        }
    }
}

struct SesoriRendezvousReader: Sendable {
    static let defaultURL: URL = {
        let configuredDataDirectory = ProcessInfo.processInfo.environment["SESORI_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dataDirectory = if let configuredDataDirectory,
                               !configuredDataDirectory.isEmpty {
            URL(fileURLWithPath: configuredDataDirectory, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/sesori", isDirectory: true)
        }
        return dataDirectory
            .appendingPathComponent("device-canvas", isDirectory: true)
            .appendingPathComponent("ipc-rendezvous.json", isDirectory: false)
    }()

    let fileURL: URL

    func read() throws -> SesoriRendezvous? {
        var fileStatus = stat()
        guard lstat(fileURL.path, &fileStatus) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var directoryStatus = stat()
        guard lstat(fileURL.deletingLastPathComponent().path, &directoryStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard fileStatus.st_uid == getuid(),
              directoryStatus.st_uid == getuid(),
              fileStatus.st_mode & S_IFMT == S_IFREG,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              fileStatus.st_mode & 0o077 == 0,
              directoryStatus.st_mode & 0o077 == 0 else {
            throw SesoriIntegrationError.insecureRendezvous
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SesoriRendezvous.self, from: data).validated()
    }
}

struct SesoriProtocolCodec: Sendable {
    func encodeHello(canvasInstanceId: String) throws -> String {
        guard !canvasInstanceId.isEmpty,
              canvasInstanceId.count <= SesoriProtocolLimits.maximumIdentifierLength else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return try encode(
            HelloMessage(
                type: "hello",
                protocolVersion: sesoriDeviceCanvasProtocolVersion,
                canvasInstanceId: canvasInstanceId,
                capabilities: .localPresentation
            )
        )
    }

    func encodeInventory(_ devices: [CanvasDeviceDescriptor]) throws -> String {
        guard devices.count <= SesoriProtocolLimits.maximumInventoryDevices,
              devices.allSatisfy(\.isValid),
              Set(devices.map(\.deviceKey)).count == devices.count else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return try encode(InventoryMessage(type: "inventorySnapshot", devices: devices))
    }

    func encodeHeartbeat(canvasInstanceId: String, observedAt: Int64) throws -> String {
        guard !canvasInstanceId.isEmpty,
              canvasInstanceId.count <= SesoriProtocolLimits.maximumIdentifierLength,
              observedAt > 0 else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return try encode(
            HeartbeatMessage(
                type: "heartbeat",
                canvasInstanceId: canvasInstanceId,
                observedAt: observedAt
            )
        )
    }

    func decodeOutbound(_ frame: String) throws -> SesoriIPCMessage {
        guard let data = frame.data(using: .utf8),
              data.count <= SesoriProtocolLimits.maximumFrameByteCount else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(MessageEnvelope.self, from: data)

        switch envelope.type {
        case "helloAccepted":
            let message = try decoder.decode(HelloAcceptedMessage.self, from: data)
            guard message.protocolVersion > 0, !message.bridgeId.isEmpty else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
            return .helloAccepted(
                protocolVersion: message.protocolVersion,
                bridgeId: message.bridgeId
            )
        case "claimsSnapshot":
            let message = try decoder.decode(ClaimsSnapshotMessage.self, from: data)
            return .claimsSnapshot(try message.claims.map { try $0.validated() })
        case "claimUpdated":
            let message = try decoder.decode(ClaimUpdatedMessage.self, from: data)
            return .claimUpdated(try message.claim.validated())
        case "claimRemoved":
            let message = try decoder.decode(ClaimRemovedMessage.self, from: data)
            guard !message.bridgeId.isEmpty,
                  !message.deviceKey.isEmpty,
                  message.revision > 0 else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
            return .claimRemoved(
                bridgeId: message.bridgeId,
                deviceKey: message.deviceKey,
                revision: message.revision
            )
        case "compatibilityStatus":
            let message = try decoder.decode(CompatibilityStatusMessage.self, from: data)
            guard message.protocolVersion > 0, !message.reason.isEmpty else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
            return .compatibilityStatus(
                supported: message.supported,
                protocolVersion: message.protocolVersion,
                reason: message.reason
            )
        default:
            throw SesoriIntegrationError.invalidProtocolMessage
        }
    }

    private func encode<T: Encodable>(_ message: T) throws -> String {
        let data = try JSONEncoder().encode(message)
        guard data.count <= SesoriProtocolLimits.maximumFrameByteCount,
              let frame = String(data: data, encoding: .utf8) else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return frame
    }
}

struct SesoriClaimProjectionState: Equatable, Sendable {
    private(set) var bridgeId: String?
    private(set) var claimsByDeviceKey: [String: SesoriClaimProjection] = [:]
    private var revisionsByDeviceKey: [String: Int] = [:]

    mutating func begin(bridgeId: String) throws {
        guard !bridgeId.isEmpty else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        self.bridgeId = bridgeId
        claimsByDeviceKey.removeAll()
        revisionsByDeviceKey.removeAll()
    }

    mutating func replaceSnapshot(_ claims: [SesoriClaimProjection]) throws {
        guard let bridgeId else {
            throw SesoriIntegrationError.unexpectedProtocolMessage
        }
        var replacement: [String: SesoriClaimProjection] = [:]
        var revisions: [String: Int] = [:]
        for claim in claims {
            let claim = try claim.validated()
            guard claim.bridgeId == bridgeId,
                  replacement.updateValue(claim, forKey: claim.deviceKey) == nil else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
            revisions[claim.deviceKey] = claim.revision
        }
        claimsByDeviceKey = replacement
        revisionsByDeviceKey = revisions
    }

    mutating func applyUpdate(_ claim: SesoriClaimProjection) throws {
        let claim = try claim.validated()
        guard claim.bridgeId == bridgeId else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        let currentRevision = revisionsByDeviceKey[claim.deviceKey] ?? 0
        guard claim.revision >= currentRevision else {
            return
        }
        if claim.revision == currentRevision {
            guard let current = claimsByDeviceKey[claim.deviceKey] else {
                return
            }
            guard current.bridgeId == claim.bridgeId,
                  current.sessionId == claim.sessionId else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
        }
        revisionsByDeviceKey[claim.deviceKey] = claim.revision
        claimsByDeviceKey[claim.deviceKey] = claim
    }

    mutating func applyRemoval(bridgeId: String, deviceKey: String, revision: Int) throws {
        guard bridgeId == self.bridgeId, !deviceKey.isEmpty, revision > 0 else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        let currentRevision = revisionsByDeviceKey[deviceKey] ?? 0
        guard revision >= currentRevision else {
            return
        }
        revisionsByDeviceKey[deviceKey] = revision
        claimsByDeviceKey.removeValue(forKey: deviceKey)
    }

    mutating func reset() {
        bridgeId = nil
        claimsByDeviceKey.removeAll()
        revisionsByDeviceKey.removeAll()
    }
}

enum SesoriSessionLinkBuilder {
    static func url(for claim: SesoriClaimProjection) -> URL? {
        guard (try? claim.validated()) != nil else {
            return nil
        }
        var pathSegmentCharacters = CharacterSet.urlPathAllowed
        pathSegmentCharacters.remove(charactersIn: "/?#")
        guard let sessionId = claim.sessionId.addingPercentEncoding(
            withAllowedCharacters: pathSegmentCharacters
        ) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "com.sesori.app"
        components.host = ""
        components.percentEncodedPath = "/sessions/\(sessionId)"
        components.queryItems = [
            URLQueryItem(name: "bridgeId", value: claim.bridgeId),
            URLQueryItem(name: "readOnly", value: "false")
        ]
        return components.url
    }
}

@MainActor
final class SesoriIntegrationClient {
    private let rendezvousReader: SesoriRendezvousReader
    private let codec = SesoriProtocolCodec()
    private let canvasInstanceId = UUID().uuidString
    private let onStatusChanged: (SesoriIntegrationStatus) -> Void
    private let onClaimsChanged: ([String: SesoriClaimProjection]) -> Void
    private let session: URLSession
    private let handshakeTimeout: Duration

    private var status = SesoriIntegrationStatus.disconnected
    private var inventory: [CanvasDeviceDescriptor] = []
    private var claimState = SesoriClaimProjectionState()
    private var activeRendezvous: SesoriRendezvous?
    private var webSocketTask: URLSessionWebSocketTask?
    private var monitorTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var helloAccepted = false
    private var claimsSnapshotReceived = false
    private var lastRendezvousError: String?

    init(
        rendezvousURL: URL = SesoriRendezvousReader.defaultURL,
        handshakeTimeout: Duration = .seconds(5),
        onStatusChanged: @escaping (SesoriIntegrationStatus) -> Void,
        onClaimsChanged: @escaping ([String: SesoriClaimProjection]) -> Void
    ) {
        rendezvousReader = SesoriRendezvousReader(fileURL: rendezvousURL)
        self.onStatusChanged = onStatusChanged
        self.onClaimsChanged = onClaimsChanged
        self.handshakeTimeout = handshakeTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    func start() {
        guard monitorTask == nil else {
            return
        }
        monitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await refreshRendezvous()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
    }

    func updateInventory(_ devices: [CanvasDeviceDescriptor]) {
        guard devices != inventory else {
            return
        }
        inventory = devices
        guard helloAccepted else {
            return
        }
        let generation = connectionGeneration
        Task { [weak self] in
            await self?.sendCurrentInventory(generation: generation)
        }
    }

    private func refreshRendezvous() async {
        do {
            let rendezvous = try rendezvousReader.read()
            lastRendezvousError = nil
            guard let rendezvous else {
                if activeRendezvous != nil || webSocketTask != nil {
                    tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
                }
                return
            }
            if rendezvous != activeRendezvous || (webSocketTask == nil && status != .incompatible) {
                connect(to: rendezvous)
            }
        } catch SesoriIntegrationError.unsupportedProtocolVersion {
            let description = SesoriIntegrationError.unsupportedProtocolVersion.localizedDescription
            if description != lastRendezvousError {
                NSLog("Sesori Device Canvas integration incompatible: %@", description)
                lastRendezvousError = description
            }
            tearDownConnection(clearActiveRendezvous: true, nextStatus: .incompatible)
        } catch {
            let description = error.localizedDescription
            if description != lastRendezvousError {
                NSLog("Sesori Device Canvas integration unavailable: %@", description)
                lastRendezvousError = description
            }
            tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
        }
    }

    private func connect(to rendezvous: SesoriRendezvous) {
        tearDownConnection(clearActiveRendezvous: true, nextStatus: .connecting)
        activeRendezvous = rendezvous
        connectionGeneration += 1
        let generation = connectionGeneration

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(rendezvous.port)")!)
        request.setValue("Bearer \(rendezvous.bearerSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        let socket = session.webSocketTask(with: request)
        webSocketTask = socket
        socket.resume()
        startHandshakeTimeout(socket: socket, generation: generation)

        receiveTask = Task { [weak self] in
            await self?.runConnection(
                socket: socket,
                rendezvous: rendezvous,
                generation: generation
            )
        }
    }

    private func runConnection(
        socket: URLSessionWebSocketTask,
        rendezvous: SesoriRendezvous,
        generation: Int
    ) async {
        do {
            try await socket.send(.string(codec.encodeHello(canvasInstanceId: canvasInstanceId)))
            while !Task.isCancelled {
                let frame = try await socket.receive()
                guard case .string(let text) = frame else {
                    throw SesoriIntegrationError.invalidProtocolMessage
                }
                try await handle(
                    codec.decodeOutbound(text),
                    socket: socket,
                    rendezvous: rendezvous,
                    generation: generation
                )
            }
        } catch {
            guard generation == connectionGeneration else {
                return
            }
            let nextStatus: SesoriIntegrationStatus = error is IncompatibleSesoriProtocol
                ? .incompatible
                : .disconnected
            tearDownConnection(
                clearActiveRendezvous: nextStatus != .incompatible,
                nextStatus: nextStatus
            )
        }
    }

    private func handle(
        _ message: SesoriIPCMessage,
        socket: URLSessionWebSocketTask,
        rendezvous: SesoriRendezvous,
        generation: Int
    ) async throws {
        guard generation == connectionGeneration, socket === webSocketTask else {
            return
        }

        switch message {
        case .helloAccepted(let protocolVersion, let bridgeId):
            guard !helloAccepted,
                  protocolVersion == sesoriDeviceCanvasProtocolVersion,
                  bridgeId == rendezvous.bridgeId else {
                throw IncompatibleSesoriProtocol()
            }
            helloAccepted = true
            try claimState.begin(bridgeId: bridgeId)
            try await socket.send(.string(codec.encodeInventory(inventory)))
            startHeartbeat(socket: socket, generation: generation)
        case .claimsSnapshot(let claims):
            guard helloAccepted, !claimsSnapshotReceived else {
                throw SesoriIntegrationError.unexpectedProtocolMessage
            }
            try claimState.replaceSnapshot(claims)
            claimsSnapshotReceived = true
            handshakeTask?.cancel()
            handshakeTask = nil
            onClaimsChanged(claimState.claimsByDeviceKey)
            setStatus(.connected)
        case .claimUpdated(let claim):
            guard claimsSnapshotReceived else {
                throw SesoriIntegrationError.unexpectedProtocolMessage
            }
            try claimState.applyUpdate(claim)
            onClaimsChanged(claimState.claimsByDeviceKey)
        case .claimRemoved(let bridgeId, let deviceKey, let revision):
            guard claimsSnapshotReceived else {
                throw SesoriIntegrationError.unexpectedProtocolMessage
            }
            try claimState.applyRemoval(
                bridgeId: bridgeId,
                deviceKey: deviceKey,
                revision: revision
            )
            onClaimsChanged(claimState.claimsByDeviceKey)
        case .compatibilityStatus(let supported, let protocolVersion, _):
            guard !supported || protocolVersion != sesoriDeviceCanvasProtocolVersion else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
            throw IncompatibleSesoriProtocol()
        }
    }

    private func startHeartbeat(socket: URLSessionWebSocketTask, generation: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                    guard generation == connectionGeneration,
                          socket === webSocketTask else {
                        return
                    }
                    let observedAt = Int64(Date().timeIntervalSince1970 * 1_000)
                    try await socket.send(
                        .string(
                            codec.encodeHeartbeat(
                                canvasInstanceId: canvasInstanceId,
                                observedAt: observedAt
                            )
                        )
                    )
                } catch {
                    guard generation == connectionGeneration else {
                        return
                    }
                    tearDownConnection(
                        clearActiveRendezvous: true,
                        nextStatus: .disconnected
                    )
                    return
                }
            }
        }
    }

    private func startHandshakeTimeout(socket: URLSessionWebSocketTask, generation: Int) {
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: handshakeTimeout)
            } catch {
                return
            }
            guard generation == connectionGeneration,
                  socket === webSocketTask,
                  !claimsSnapshotReceived else {
                return
            }
            tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
        }
    }

    private func sendCurrentInventory(generation: Int) async {
        guard generation == connectionGeneration,
              helloAccepted,
              let socket = webSocketTask else {
            return
        }
        do {
            try await socket.send(.string(codec.encodeInventory(inventory)))
        } catch {
            guard generation == connectionGeneration else {
                return
            }
            tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
        }
    }

    private func tearDownConnection(
        clearActiveRendezvous: Bool,
        nextStatus: SesoriIntegrationStatus
    ) {
        connectionGeneration += 1
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        helloAccepted = false
        claimsSnapshotReceived = false
        if clearActiveRendezvous {
            activeRendezvous = nil
        }
        if !claimState.claimsByDeviceKey.isEmpty {
            claimState.reset()
            onClaimsChanged([:])
        } else {
            claimState.reset()
        }
        setStatus(nextStatus)
    }

    private func setStatus(_ status: SesoriIntegrationStatus) {
        guard self.status != status else {
            return
        }
        self.status = status
        onStatusChanged(status)
    }
}

private struct MessageEnvelope: Decodable {
    let type: String
}

private struct HelloMessage: Encodable {
    let type: String
    let protocolVersion: Int
    let canvasInstanceId: String
    let capabilities: CanvasCapabilities
}

private struct InventoryMessage: Encodable {
    let type: String
    let devices: [CanvasDeviceDescriptor]
}

private struct HeartbeatMessage: Encodable {
    let type: String
    let canvasInstanceId: String
    let observedAt: Int64
}

private struct HelloAcceptedMessage: Decodable {
    let protocolVersion: Int
    let bridgeId: String
}

private struct ClaimsSnapshotMessage: Decodable {
    let claims: [SesoriClaimProjection]
}

private struct ClaimUpdatedMessage: Decodable {
    let claim: SesoriClaimProjection
}

private struct ClaimRemovedMessage: Decodable {
    let bridgeId: String
    let deviceKey: String
    let revision: Int
}

private struct CompatibilityStatusMessage: Decodable {
    let supported: Bool
    let protocolVersion: Int
    let reason: String
}

private struct IncompatibleSesoriProtocol: Error {}
