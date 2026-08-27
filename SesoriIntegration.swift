import Darwin
import Foundation

let sesoriDeviceCanvasProtocolVersion = 3

private enum SesoriProtocolLimits {
    static let maximumFrameByteCount = 1_048_576
    static let maximumInventoryDevices = 64
    static let maximumIdentifierLength = 512
    static let maximumDisplayLength = 512
    static let maximumDimension = 32_768
    static let maximumSDPByteCount = 262_144
    static let maximumFingerprintLength = 256
    static let maximumICECandidates = 64
    static let maximumCandidateLength = 2_048
    static let maximumSDPMidLength = 128
    static let maximumTURNURLs = 8
    static let maximumTURNURLLength = 2_048
    static let maximumTURNUsernameByteCount = 509
    static let maximumTURNCredentialLength = 512
    static let maximumStreamCorrelationsPerConnection = 4_096
    static let maximumRequestIdentifierLength = 128
}

private extension String {
    func hasUTF16Length(in range: ClosedRange<Int>) -> Bool {
        range.contains(utf16.count)
    }
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

    static let androidRemoteVideo = CanvasCapabilities(
        localView: true,
        remoteVideo: true,
        remoteControl: false,
        input: true
    )
}

enum SesoriRTCDescriptionType: String, Codable, Sendable {
    case offer
    case answer
}

struct SesoriRTCDescription: Codable, Equatable, Sendable {
    let type: SesoriRTCDescriptionType
    let sdp: String
    let fingerprint: String

    var isValid: Bool {
        guard !sdp.isEmpty,
              sdp.utf8.count <= SesoriProtocolLimits.maximumSDPByteCount,
              fingerprint.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumFingerprintLength),
              Self.isValidFingerprint(fingerprint) else {
            return false
        }

        let normalizedSDP = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedSDP.contains("\r") else {
            return false
        }
        let fingerprintLines = normalizedSDP
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("a=fingerprint:") }
        return fingerprintLines.count == 1
            && fingerprintLines[0] == Substring("a=fingerprint:\(fingerprint)")
    }

    private static func isValidFingerprint(_ fingerprint: String) -> Bool {
        let prefix = "sha-256 "
        guard fingerprint.hasPrefix(prefix) else {
            return false
        }
        let octets = fingerprint.dropFirst(prefix.count).split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        return octets.count == 32 && octets.allSatisfy { octet in
            octet.utf8.count == 2 && octet.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }
        }
    }
}

struct SesoriICECandidate: Codable, Equatable, Sendable {
    let candidate: String
    let sdpMid: String
    let sdpMLineIndex: Int32

    var isValid: Bool {
        candidate.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumCandidateLength)
            && sdpMid.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumSDPMidLength)
            && sdpMLineIndex >= 0
    }
}

struct SesoriTURNConfiguration: Codable, Equatable, Sendable {
    let urls: [String]
    let username: String
    let credential: String
    let expiresAt: Int64

    var canonicalURLs: [String]? {
        guard (1...SesoriProtocolLimits.maximumTURNURLs).contains(urls.count) else {
            return nil
        }
        let canonical = urls.compactMap(Self.normalizedURL)
        guard canonical.count == urls.count,
              Set(canonical).count == canonical.count else {
            return nil
        }
        return canonical
    }

    var isValid: Bool {
        canonicalURLs != nil
            && (1...SesoriProtocolLimits.maximumTURNUsernameByteCount).contains(username.utf8.count)
            && credential.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumTURNCredentialLength)
            && expiresAt > 0
    }

    private static func normalizedURL(_ value: String) -> String? {
        guard value.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumTURNURLLength),
              value.rangeOfCharacter(
                  from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
              ) == nil else {
            return nil
        }

        guard let schemeEnd = value.firstIndex(of: ":") else {
            return nil
        }
        let scheme = value[..<schemeEnd].lowercased()
        guard scheme == "turn" || scheme == "turns" else {
            return nil
        }
        let remainder = value[value.index(after: schemeEnd)...]

        let components = remainder.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let defaultTransport = scheme == "turn" ? "udp" : "tcp"
        let transport: String
        if components.count == 1 {
            transport = defaultTransport
        } else {
            let query = components[1].lowercased()
            guard query == "transport=udp" || query == "transport=tcp" else {
                return nil
            }
            transport = String(query.dropFirst("transport=".count))
        }
        guard !components[0].isEmpty,
              let authority = normalizedAuthority(components[0]) else {
            return nil
        }

        let port = authority.port ?? (scheme == "turn" ? 3_478 : 5_349)
        return "\(scheme):\(authority.host):\(port)?transport=\(transport)"
    }

    private static func normalizedAuthority(
        _ authority: Substring
    ) -> (host: String, port: Int?)? {
        guard !authority.contains("/"),
              !authority.contains("@"),
              !authority.contains("#") else {
            return nil
        }

        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]"),
                  closingBracket > authority.startIndex else {
                return nil
            }
            let host = String(authority[authority.index(after: authority.startIndex)..<closingBracket])
            var address = in6_addr()
            guard !host.contains("."),
                  host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1,
                  !isIPv4EmbeddedIPv6(address) else {
                return nil
            }

            let suffix = authority[authority.index(after: closingBracket)...]
            let port: Int?
            if suffix.isEmpty {
                port = nil
            } else {
                guard suffix.first == ":", let parsedPort = normalizedPort(suffix.dropFirst()) else {
                    return nil
                }
                port = parsedPort
            }
            return (normalizedIPv6Host(address), port)
        }

        guard !authority.contains("[") && !authority.contains("]") else {
            return nil
        }
        let hostAndPort = authority.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let host = normalizedHost(hostAndPort[0]) else {
            return nil
        }
        if hostAndPort.count == 1 {
            return (host, nil)
        }
        guard let port = normalizedPort(hostAndPort[1]) else {
            return nil
        }
        return (host, port)
    }

    private static func normalizedHost(_ host: Substring) -> String? {
        guard !host.isEmpty, host.utf8.count <= 253 else {
            return nil
        }

        let hostString = String(host)
        var ipv4 = in_addr()
        if hostString.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let canonical = normalizedIPv4Host(ipv4)
            return hostString == canonical ? canonical : nil
        }
        guard !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              !isAlternateNumericHost(hostString) else {
            return nil
        }

        let dnsHost = host.last == "." ? host.dropLast() : host
        guard !dnsHost.isEmpty else {
            return nil
        }
        let labels = dnsHost.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard (1...63).contains(label.utf8.count),
                  let first = label.utf8.first,
                  let last = label.utf8.last,
                  isASCIIAlphaNumeric(first),
                  isASCIIAlphaNumeric(last) else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                isASCIIAlphaNumeric(byte) || byte == 45
            }
        }) else {
            return nil
        }
        return dnsHost.lowercased()
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func normalizedPort(_ port: Substring) -> Int? {
        guard !port.isEmpty,
              port.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(port),
              (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    private static func normalizedIPv6Host(_ address: in6_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &address) { pointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                _ = inet_ntop(
                    AF_INET6,
                    pointer,
                    bufferPointer.baseAddress,
                    socklen_t(bufferPointer.count)
                )
                return "[\(String(cString: bufferPointer.baseAddress!))]"
            }
        }
    }

    private static func normalizedIPv4Host(_ address: in_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return withUnsafePointer(to: &address) { pointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                _ = inet_ntop(
                    AF_INET,
                    pointer,
                    bufferPointer.baseAddress,
                    socklen_t(bufferPointer.count)
                )
                return String(cString: bufferPointer.baseAddress!)
            }
        }
    }

    private static func isAlternateNumericHost(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
        if let result {
            freeaddrinfo(result)
        }
        return status == 0
    }

    private static func isIPv4EmbeddedIPv6(_ address: in6_addr) -> Bool {
        withUnsafeBytes(of: address) { bytes in
            // These legacy prefixes can spell an IPv4 endpoint as an IPv6 literal.
            let specialIPv6 = bytes[0..<15].allSatisfy { $0 == 0 }
                && (bytes[15] == 0 || bytes[15] == 1)
            let compatible = bytes[0..<12].allSatisfy { $0 == 0 }
                && !specialIPv6
            let mapped = bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff
            let translatable = bytes[0..<8].allSatisfy { $0 == 0 }
                && bytes[8] == 0xff && bytes[9] == 0xff
                && bytes[10] == 0 && bytes[11] == 0
            return compatible || mapped || translatable
        }
    }
}

struct SesoriStreamStartRequest: Codable, Equatable, Sendable {
    let requestId: String
    let leaseId: String
    let bridgeId: String
    let sessionId: String
    let deviceKey: String
    let claimRevision: Int
    let expiresAt: Int64
    let control: Bool
    let offer: SesoriRTCDescription
    let iceCandidates: [SesoriICECandidate]
    let turn: SesoriTURNConfiguration?

    var isValid: Bool {
        requestId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength)
            && leaseId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength)
            && bridgeId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumIdentifierLength)
            && sessionId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumIdentifierLength)
            && deviceKey.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumIdentifierLength)
            && claimRevision > 0
            && expiresAt > 0
            && offer.type == .offer
            && offer.isValid
            && iceCandidates.count <= SesoriProtocolLimits.maximumICECandidates
            && iceCandidates.allSatisfy(\.isValid)
            && (turn?.isValid ?? true)
    }

    var effectiveExpiresAt: Int64 {
        min(expiresAt, turn?.expiresAt ?? Int64.max)
    }
}

enum SesoriStreamStartFailureReason: String, Codable, Sendable {
    case unsupported
    case invalidOffer
    case peerSetupFailed
}

enum SesoriStreamRevokeReason: String, Codable, Sendable {
    case stopped
    case expired
    case claimChanged
    case clientDisconnected
    case canvasDisconnected
    case deviceUnavailable
    case bridgeShutdown
    case startFailed
}

enum SesoriStreamClosedReason: String, Codable, Sendable {
    case stopped
    case failed
}

enum SesoriRemoteStreamStartResult: Sendable {
    case started(answer: SesoriRTCDescription, iceCandidates: [SesoriICECandidate])
    case failed(SesoriStreamStartFailureReason)
}

@MainActor
protocol SesoriRemoteStreamHandling: AnyObject {
    var capabilities: CanvasCapabilities { get }
    func startStream(_ request: SesoriStreamStartRequest) async -> SesoriRemoteStreamStartResult
    func revokeStream(leaseId: String, reason: SesoriStreamRevokeReason)
    func closeAllStreams()
    func setStreamClosedHandler(
        _ handler: @escaping @MainActor (String, SesoriStreamClosedReason) -> Void
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
    case streamStart(SesoriStreamStartRequest)
    case invalidStreamStart(requestId: String, leaseId: String)
    case streamRevoke(leaseId: String, reason: SesoriStreamRevokeReason)
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
    func encodeHello(
        canvasInstanceId: String,
        capabilities: CanvasCapabilities = .localPresentation
    ) throws -> String {
        guard !canvasInstanceId.isEmpty,
              canvasInstanceId.count <= SesoriProtocolLimits.maximumIdentifierLength else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return try encode(
            HelloMessage(
                type: "hello",
                protocolVersion: sesoriDeviceCanvasProtocolVersion,
                canvasInstanceId: canvasInstanceId,
                capabilities: capabilities
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

    func encodeStreamStarted(
        requestId: String,
        leaseId: String,
        answer: SesoriRTCDescription,
        iceCandidates: [SesoriICECandidate]
    ) throws -> String {
        guard requestId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength),
              leaseId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength),
              answer.type == .answer,
              answer.isValid,
              iceCandidates.count <= SesoriProtocolLimits.maximumICECandidates,
              iceCandidates.allSatisfy(\.isValid) else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return try encode(
            StreamStartedMessage(
                type: "streamStarted",
                requestId: requestId,
                leaseId: leaseId,
                answer: answer,
                iceCandidates: iceCandidates
            )
        )
    }

    func encodeStreamStartFailed(
        requestId: String,
        leaseId: String,
        reason: SesoriStreamStartFailureReason
    ) throws -> String {
        guard requestId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength),
              leaseId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength) else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return try encode(
            StreamStartFailedMessage(
                type: "streamStartFailed",
                requestId: requestId,
                leaseId: leaseId,
                reason: reason
            )
        )
    }

    func encodeStreamClosed(
        leaseId: String,
        reason: SesoriStreamClosedReason
    ) throws -> String {
        guard leaseId.hasUTF16Length(in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength) else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return try encode(
            StreamClosedMessage(type: "streamClosed", leaseId: leaseId, reason: reason)
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
        case "streamStart":
            guard let message = try? decoder.decode(StreamStartMessage.self, from: data) else {
                let correlation = try decoder.decode(StreamStartCorrelationMessage.self, from: data)
                return try invalidStreamStart(
                    requestId: correlation.requestId,
                    leaseId: correlation.leaseId
                )
            }
            guard message.request.isValid else {
                return try invalidStreamStart(
                    requestId: message.request.requestId,
                    leaseId: message.request.leaseId
                )
            }
            return .streamStart(message.request)
        case "streamRevoke":
            let message = try decoder.decode(StreamRevokeMessage.self, from: data)
            guard message.leaseId.hasUTF16Length(
                in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength
            ) else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
            return .streamRevoke(leaseId: message.leaseId, reason: message.reason)
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

    private func invalidStreamStart(requestId: String, leaseId: String) throws -> SesoriIPCMessage {
        guard requestId.hasUTF16Length(
            in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength
        ), leaseId.hasUTF16Length(
            in: 1...SesoriProtocolLimits.maximumRequestIdentifierLength
        ) else {
            throw SesoriIntegrationError.invalidProtocolMessage
        }
        return .invalidStreamStart(requestId: requestId, leaseId: leaseId)
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
    private let remoteStreams: (any SesoriRemoteStreamHandling)?
    private let socketSender: @MainActor (
        URLSessionWebSocketTask,
        URLSessionWebSocketTask.Message
    ) async throws -> Void

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
    private var remoteStreamEntriesByLeaseId: [String: RemoteStreamEntry] = [:]
    private var remoteStreamLeaseIdByDeviceKey: [String: String] = [:]
    private var remoteStreamTasksByLeaseId: [String: Task<Void, Never>] = [:]
    private var remoteStreamExpiryTasksByLeaseId: [String: Task<Void, Never>] = [:]
    private var remoteStreamRequestIds: Set<String> = []
    private var remoteStreamLeaseIds: Set<String> = []

    init(
        rendezvousURL: URL = SesoriRendezvousReader.defaultURL,
        handshakeTimeout: Duration = .seconds(5),
        remoteStreams: (any SesoriRemoteStreamHandling)? = nil,
        onStatusChanged: @escaping (SesoriIntegrationStatus) -> Void,
        onClaimsChanged: @escaping ([String: SesoriClaimProjection]) -> Void,
        socketSender: @escaping @MainActor (
            URLSessionWebSocketTask,
            URLSessionWebSocketTask.Message
        ) async throws -> Void = { socket, message in
            try await socket.send(message)
        }
    ) {
        rendezvousReader = SesoriRendezvousReader(fileURL: rendezvousURL)
        self.onStatusChanged = onStatusChanged
        self.onClaimsChanged = onClaimsChanged
        self.handshakeTimeout = handshakeTimeout
        self.remoteStreams = remoteStreams
        self.socketSender = socketSender
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        remoteStreams?.setStreamClosedHandler { _, _ in }
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
        remoteStreams?.setStreamClosedHandler { [weak self, weak socket] leaseId, reason in
            guard let socket else { return }
            self?.remoteStreamClosed(
                leaseId: leaseId,
                reason: reason,
                socket: socket,
                generation: generation
            )
        }
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
            try await socketSender(
                socket,
                .string(
                    codec.encodeHello(
                        canvasInstanceId: canvasInstanceId,
                        capabilities: remoteStreams?.capabilities ?? .localPresentation
                    )
                )
            )
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
            try await socketSender(socket, .string(codec.encodeInventory(inventory)))
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
            await revokeStreamIfClaimChanged(
                deviceKey: claim.deviceKey,
                socket: socket,
                generation: generation
            )
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
            await revokeStreamIfClaimChanged(
                deviceKey: deviceKey,
                socket: socket,
                generation: generation
            )
        case .compatibilityStatus(let supported, let protocolVersion, _):
            guard !supported || protocolVersion != sesoriDeviceCanvasProtocolVersion else {
                throw SesoriIntegrationError.invalidProtocolMessage
            }
            throw IncompatibleSesoriProtocol()
        case .streamStart(let request):
            try await handleStreamStart(
                request,
                socket: socket,
                rendezvous: rendezvous,
                generation: generation
            )
        case .invalidStreamStart(let requestId, let leaseId):
            guard claimsSnapshotReceived else {
                throw SesoriIntegrationError.unexpectedProtocolMessage
            }
            guard reserveRemoteStreamCorrelation(
                requestId: requestId,
                leaseId: leaseId
            ) else {
                tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
                return
            }
            await sendStreamStartFailed(
                requestId: requestId,
                leaseId: leaseId,
                reason: .peerSetupFailed,
                socket: socket,
                generation: generation
            )
        case .streamRevoke(let leaseId, let reason):
            await handleStreamRevoke(
                leaseId: leaseId,
                reason: reason,
                socket: socket,
                generation: generation
            )
        }
    }

    private func handleStreamStart(
        _ request: SesoriStreamStartRequest,
        socket: URLSessionWebSocketTask,
        rendezvous: SesoriRendezvous,
        generation: Int
    ) async throws {
        guard reserveRemoteStreamCorrelation(
            requestId: request.requestId,
            leaseId: request.leaseId
        ) else {
            tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
            return
        }

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard request.effectiveExpiresAt > now else {
            try await socketSender(
                socket,
                .string(
                    codec.encodeStreamStartFailed(
                        requestId: request.requestId,
                        leaseId: request.leaseId,
                        reason: .peerSetupFailed
                    )
                )
            )
            return
        }

        guard claimsSnapshotReceived,
              request.bridgeId == rendezvous.bridgeId,
              activeRendezvous?.bridgeId == request.bridgeId,
              let claim = claimState.claimsByDeviceKey[request.deviceKey],
              claim.bridgeId == request.bridgeId,
              claim.sessionId == request.sessionId,
              claim.revision == request.claimRevision,
              let descriptor = inventory.first(where: { $0.deviceKey == request.deviceKey }),
              descriptor.capabilities.remoteVideo,
              let remoteStreams,
              remoteStreams.capabilities.remoteVideo,
              !request.control || (
                  descriptor.capabilities.remoteControl
                      && descriptor.capabilities.input
                      && remoteStreams.capabilities.remoteControl
                      && remoteStreams.capabilities.input
              ) else {
            try await socketSender(
                socket,
                .string(
                    codec.encodeStreamStartFailed(
                        requestId: request.requestId,
                        leaseId: request.leaseId,
                        reason: .unsupported
                    )
                )
            )
            return
        }

        guard remoteStreamEntriesByLeaseId[request.leaseId] == nil,
              remoteStreamLeaseIdByDeviceKey[request.deviceKey] == nil else {
            try await socketSender(
                socket,
                .string(
                    codec.encodeStreamStartFailed(
                        requestId: request.requestId,
                        leaseId: request.leaseId,
                        reason: .peerSetupFailed
                    )
                )
            )
            return
        }

        let expiresAt = request.effectiveExpiresAt
        let schedulingNow = Int64(Date().timeIntervalSince1970 * 1_000)
        guard expiresAt > schedulingNow else {
            try await socketSender(
                socket,
                .string(
                    codec.encodeStreamStartFailed(
                        requestId: request.requestId,
                        leaseId: request.leaseId,
                        reason: .peerSetupFailed
                    )
                )
            )
            return
        }

        let token = UUID()
        remoteStreamEntriesByLeaseId[request.leaseId] = RemoteStreamEntry(
            requestId: request.requestId,
            leaseId: request.leaseId,
            deviceKey: request.deviceKey,
            sessionId: request.sessionId,
            claimRevision: request.claimRevision,
            token: token,
            socket: socket,
            generation: generation,
            phase: .pending
        )
        remoteStreamLeaseIdByDeviceKey[request.deviceKey] = request.leaseId
        let clock = ContinuousClock()
        let monotonicDeadline = clock.now.advanced(
            by: .milliseconds(expiresAt - schedulingNow)
        )
        remoteStreamExpiryTasksByLeaseId[request.leaseId] = Task.detached { [weak self] in
            do {
                // The monotonic bound resists scheduler delay; wall checks catch clock jumps.
                while clock.now < monotonicDeadline {
                    let wallRemaining = expiresAt
                        - Int64(Date().timeIntervalSince1970 * 1_000)
                    guard wallRemaining > 0 else { break }
                    let nextWallCheck = clock.now.advanced(
                        by: .milliseconds(min(wallRemaining, 250))
                    )
                    try await clock.sleep(until: min(monotonicDeadline, nextWallCheck))
                }
            } catch {
                return
            }
            await self?.expireRemoteStream(
                leaseId: request.leaseId,
                token: token,
                generation: generation
            )
        }
        let task = Task { [weak self] in
            let result = await remoteStreams.startStream(request)
            guard !Task.isCancelled else { return }
            await self?.completeStreamStart(
                result,
                request: request,
                token: token,
                socket: socket,
                generation: generation
            )
        }
        remoteStreamTasksByLeaseId[request.leaseId] = task
    }

    private func completeStreamStart(
        _ result: SesoriRemoteStreamStartResult,
        request: SesoriStreamStartRequest,
        token: UUID,
        socket: URLSessionWebSocketTask,
        generation: Int
    ) async {
        guard generation == connectionGeneration,
              socket === webSocketTask,
              let entry = remoteStreamEntriesByLeaseId[request.leaseId],
              entry.token == token,
              entry.leaseId == request.leaseId,
              entry.requestId == request.requestId,
              entry.generation == generation,
              entry.socket === socket,
              entry.phase == .pending else {
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard request.effectiveExpiresAt > now else {
            remoteStreamTasksByLeaseId[request.leaseId] = nil
            removeRemoteStreamEntry(entry)
            remoteStreams?.revokeStream(leaseId: request.leaseId, reason: .expired)
            await sendStreamStartFailed(
                requestId: request.requestId,
                leaseId: request.leaseId,
                reason: .peerSetupFailed,
                socket: socket,
                generation: generation
            )
            return
        }

        switch result {
        case .failed(let reason):
            remoteStreamTasksByLeaseId[request.leaseId] = nil
            removeRemoteStreamEntry(entry)
            await sendStreamStartFailed(
                requestId: request.requestId,
                leaseId: request.leaseId,
                reason: reason,
                socket: socket,
                generation: generation
            )
        case .started(let answer, let iceCandidates):
            guard answer.type == .answer,
                  answer.isValid,
                  iceCandidates.count <= SesoriProtocolLimits.maximumICECandidates,
                  iceCandidates.allSatisfy(\.isValid) else {
                remoteStreamTasksByLeaseId[request.leaseId] = nil
                removeRemoteStreamEntry(entry)
                remoteStreams?.revokeStream(leaseId: request.leaseId, reason: .startFailed)
                await sendStreamStartFailed(
                    requestId: request.requestId,
                    leaseId: request.leaseId,
                    reason: .peerSetupFailed,
                    socket: socket,
                    generation: generation
                )
                return
            }
            var sendingEntry = entry
            sendingEntry.phase = .sending
            remoteStreamEntriesByLeaseId[request.leaseId] = sendingEntry
            guard await sendStreamStarted(
                requestId: request.requestId,
                leaseId: request.leaseId,
                answer: answer,
                iceCandidates: iceCandidates,
                socket: socket,
                generation: generation
            ) else {
                return
            }

            guard generation == connectionGeneration,
                  socket === webSocketTask,
                  let currentEntry = remoteStreamEntriesByLeaseId[request.leaseId],
                  currentEntry.token == token,
                  currentEntry.phase == .sending else {
                return
            }
            guard request.effectiveExpiresAt
                > Int64(Date().timeIntervalSince1970 * 1_000) else {
                removeRemoteStreamEntry(currentEntry)
                remoteStreams?.revokeStream(leaseId: request.leaseId, reason: .expired)
                tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
                return
            }
            var activeEntry = currentEntry
            activeEntry.phase = .active
            remoteStreamEntriesByLeaseId[request.leaseId] = activeEntry
            remoteStreamTasksByLeaseId[request.leaseId] = nil
        }
    }

    private func expireRemoteStream(leaseId: String, token: UUID, generation: Int) async {
        guard generation == connectionGeneration,
              let socket = webSocketTask,
              let entry = remoteStreamEntriesByLeaseId[leaseId],
              entry.token == token,
              entry.socket === socket else {
            return
        }
        await handleStreamRevoke(
            leaseId: leaseId,
            reason: .expired,
            socket: socket,
            generation: generation
        )
    }

    private func handleStreamRevoke(
        leaseId: String,
        reason: SesoriStreamRevokeReason,
        socket: URLSessionWebSocketTask,
        generation: Int
    ) async {
        guard generation == connectionGeneration,
              socket === webSocketTask,
              let entry = remoteStreamEntriesByLeaseId[leaseId] else {
            return
        }

        let phase = entry.phase
        removeRemoteStreamEntry(entry)
        remoteStreamTasksByLeaseId[leaseId]?.cancel()
        remoteStreamTasksByLeaseId[leaseId] = nil
        remoteStreams?.revokeStream(leaseId: leaseId, reason: reason)
        if phase == .sending {
            tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
        } else if phase == .pending {
            await sendStreamStartFailed(
                requestId: entry.requestId,
                leaseId: leaseId,
                reason: .peerSetupFailed,
                socket: socket,
                generation: generation
            )
        }
    }

    private func revokeStreamIfClaimChanged(
        deviceKey: String,
        socket: URLSessionWebSocketTask,
        generation: Int
    ) async {
        guard let leaseId = remoteStreamLeaseIdByDeviceKey[deviceKey],
              let entry = remoteStreamEntriesByLeaseId[leaseId] else {
            return
        }
        if let claim = claimState.claimsByDeviceKey[deviceKey],
           claim.sessionId == entry.sessionId,
           claim.revision == entry.claimRevision {
            return
        }
        await handleStreamRevoke(
            leaseId: leaseId,
            reason: .claimChanged,
            socket: socket,
            generation: generation
        )
    }

    private func reserveRemoteStreamCorrelation(requestId: String, leaseId: String) -> Bool {
        guard remoteStreamRequestIds.count
                < SesoriProtocolLimits.maximumStreamCorrelationsPerConnection,
              !remoteStreamRequestIds.contains(requestId),
              !remoteStreamLeaseIds.contains(leaseId) else {
            return false
        }
        remoteStreamRequestIds.insert(requestId)
        remoteStreamLeaseIds.insert(leaseId)
        return true
    }

    private func remoteStreamClosed(
        leaseId: String,
        reason: SesoriStreamClosedReason,
        socket: URLSessionWebSocketTask,
        generation: Int
    ) {
        guard generation == connectionGeneration,
              socket === webSocketTask,
              let entry = remoteStreamEntriesByLeaseId[leaseId],
              entry.socket === socket else {
            return
        }
        if entry.phase == .sending {
            removeRemoteStreamEntry(entry)
            tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
            return
        }
        guard entry.phase == .active else { return }
        removeRemoteStreamEntry(entry)
        Task { [weak self] in
            await self?.sendStreamClosed(
                leaseId: leaseId,
                reason: reason,
                socket: socket,
                generation: generation
            )
        }
    }

    private func sendStreamStarted(
        requestId: String,
        leaseId: String,
        answer: SesoriRTCDescription,
        iceCandidates: [SesoriICECandidate],
        socket: URLSessionWebSocketTask,
        generation: Int
    ) async -> Bool {
        do {
            try await socketSender(
                socket,
                .string(
                    codec.encodeStreamStarted(
                        requestId: requestId,
                        leaseId: leaseId,
                        answer: answer,
                        iceCandidates: iceCandidates
                    )
                )
            )
            return true
        } catch {
            handleStreamSendFailure(socket: socket, generation: generation)
            return false
        }
    }

    private func sendStreamStartFailed(
        requestId: String,
        leaseId: String,
        reason: SesoriStreamStartFailureReason,
        socket: URLSessionWebSocketTask,
        generation: Int
    ) async {
        do {
            try await socketSender(
                socket,
                .string(
                    codec.encodeStreamStartFailed(
                        requestId: requestId,
                        leaseId: leaseId,
                        reason: reason
                    )
                )
            )
        } catch {
            handleStreamSendFailure(socket: socket, generation: generation)
        }
    }

    private func sendStreamClosed(
        leaseId: String,
        reason: SesoriStreamClosedReason,
        socket: URLSessionWebSocketTask,
        generation: Int
    ) async {
        do {
            try await socketSender(
                socket,
                .string(codec.encodeStreamClosed(leaseId: leaseId, reason: reason))
            )
        } catch {
            handleStreamSendFailure(socket: socket, generation: generation)
        }
    }

    private func handleStreamSendFailure(socket: URLSessionWebSocketTask, generation: Int) {
        guard generation == connectionGeneration, socket === webSocketTask else {
            return
        }
        tearDownConnection(clearActiveRendezvous: true, nextStatus: .disconnected)
    }

    private func removeRemoteStreamEntry(_ entry: RemoteStreamEntry) {
        guard remoteStreamEntriesByLeaseId[entry.leaseId]?.token == entry.token else {
            return
        }
        remoteStreamEntriesByLeaseId[entry.leaseId] = nil
        remoteStreamExpiryTasksByLeaseId.removeValue(forKey: entry.leaseId)?.cancel()
        if remoteStreamLeaseIdByDeviceKey[entry.deviceKey] == entry.leaseId {
            remoteStreamLeaseIdByDeviceKey[entry.deviceKey] = nil
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
                    try await socketSender(
                        socket,
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
            try await socketSender(socket, .string(codec.encodeInventory(inventory)))
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
        let hadRemoteStreams = !remoteStreamEntriesByLeaseId.isEmpty
        remoteStreamTasksByLeaseId.values.forEach { $0.cancel() }
        remoteStreamTasksByLeaseId.removeAll()
        remoteStreamExpiryTasksByLeaseId.values.forEach { $0.cancel() }
        remoteStreamExpiryTasksByLeaseId.removeAll()
        remoteStreamEntriesByLeaseId.removeAll()
        remoteStreamLeaseIdByDeviceKey.removeAll()
        remoteStreamRequestIds.removeAll()
        remoteStreamLeaseIds.removeAll()
        remoteStreams?.setStreamClosedHandler { _, _ in }
        if hadRemoteStreams {
            remoteStreams?.closeAllStreams()
        }
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

    private enum RemoteStreamPhase: Equatable {
        case pending
        case sending
        case active
    }

    private struct RemoteStreamEntry {
        let requestId: String
        let leaseId: String
        let deviceKey: String
        let sessionId: String
        let claimRevision: Int
        let token: UUID
        let socket: URLSessionWebSocketTask
        let generation: Int
        var phase: RemoteStreamPhase
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

private struct StreamStartedMessage: Encodable {
    let type: String
    let requestId: String
    let leaseId: String
    let answer: SesoriRTCDescription
    let iceCandidates: [SesoriICECandidate]
}

private struct StreamStartFailedMessage: Encodable {
    let type: String
    let requestId: String
    let leaseId: String
    let reason: SesoriStreamStartFailureReason
}

private struct StreamClosedMessage: Encodable {
    let type: String
    let leaseId: String
    let reason: SesoriStreamClosedReason
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

private struct StreamStartMessage: Decodable {
    let requestId: String
    let leaseId: String
    let bridgeId: String
    let sessionId: String
    let deviceKey: String
    let claimRevision: Int
    let expiresAt: Int64
    let control: Bool
    let offer: SesoriRTCDescription
    let iceCandidates: [SesoriICECandidate]
    let turn: SesoriTURNConfiguration?

    var request: SesoriStreamStartRequest {
        SesoriStreamStartRequest(
            requestId: requestId,
            leaseId: leaseId,
            bridgeId: bridgeId,
            sessionId: sessionId,
            deviceKey: deviceKey,
            claimRevision: claimRevision,
            expiresAt: expiresAt,
            control: control,
            offer: offer,
            iceCandidates: iceCandidates,
            turn: turn
        )
    }
}

private struct StreamStartCorrelationMessage: Decodable {
    let requestId: String
    let leaseId: String
}

private struct StreamRevokeMessage: Decodable {
    let leaseId: String
    let reason: SesoriStreamRevokeReason
}

private struct IncompatibleSesoriProtocol: Error {}
