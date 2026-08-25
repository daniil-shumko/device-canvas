import Darwin
import Foundation
import Network

@main
private enum SesoriIntegrationTests {
    static func main() async throws {
        try testRendezvousValidationAndPermissions()
        try await testUnsupportedRendezvousStatusAndRecovery()
        try await testHandshakeTimeout()
        try testInboundEncoding()
        try testOutboundDecoding()
        try testSnapshotReplacementAndRevisionFencing()
        try testDeepLinkEncoding()
        print("Sesori integration protocol tests passed")
    }

    @MainActor
    private static func testHandshakeTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-canvas-handshake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard chmod(directory.path, 0o700) == 0 else {
            throw TestFailure("failed to set handshake test directory permissions")
        }

        let server = try MockSesoriWebSocketServer(bridgeId: "bridge-a", respondsToHello: false)
        let serverPort = try server.start()
        defer { server.stop() }
        let file = directory.appendingPathComponent("ipc-rendezvous.json")
        let rendezvous = SesoriRendezvous(
            protocolVersion: sesoriDeviceCanvasProtocolVersion,
            port: serverPort,
            bearerSecret: "test-secret",
            bridgeId: "bridge-a",
            processGeneration: "process-a"
        )
        try JSONEncoder().encode(rendezvous).write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
            throw TestFailure("failed to set handshake rendezvous permissions")
        }

        var statuses: [SesoriIntegrationStatus] = []
        let client = SesoriIntegrationClient(
            rendezvousURL: file,
            handshakeTimeout: .milliseconds(100),
            onStatusChanged: { statuses.append($0) },
            onClaimsChanged: { _ in }
        )
        client.start()
        defer { client.stop() }

        try await waitUntil("an incomplete handshake should disconnect") {
            statuses.contains(.connecting) && statuses.contains(.disconnected)
        }
    }

    @MainActor
    private static func testUnsupportedRendezvousStatusAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-canvas-incompatible-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard chmod(directory.path, 0o700) == 0 else {
            throw TestFailure("failed to set incompatible test directory permissions")
        }

        let file = directory.appendingPathComponent("ipc-rendezvous.json")
        let server = try MockSesoriWebSocketServer(bridgeId: "bridge-b")
        let serverPort = try server.start()
        defer { server.stop() }
        let incompatible = SesoriRendezvous(
            protocolVersion: sesoriDeviceCanvasProtocolVersion + 1,
            port: 41_234,
            bearerSecret: "test-secret",
            bridgeId: "bridge-a",
            processGeneration: "process-a"
        )
        try JSONEncoder().encode(incompatible).write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
            throw TestFailure("failed to set incompatible rendezvous permissions")
        }

        var statuses: [SesoriIntegrationStatus] = []
        var snapshotCount = 0
        let client = SesoriIntegrationClient(
            rendezvousURL: file,
            onStatusChanged: { statuses.append($0) },
            onClaimsChanged: { _ in snapshotCount += 1 }
        )
        client.start()
        defer { client.stop() }

        try await waitUntil("unsupported rendezvous should report incompatibility") {
            statuses.contains(.incompatible)
        }

        let compatible = SesoriRendezvous(
            protocolVersion: sesoriDeviceCanvasProtocolVersion,
            port: serverPort,
            bearerSecret: "test-secret-2",
            bridgeId: "bridge-b",
            processGeneration: "process-b"
        )
        try JSONEncoder().encode(compatible).write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
            throw TestFailure("failed to set compatible rendezvous permissions")
        }

        try await waitUntil("a compatible replacement should complete the protocol handshake") {
            statuses.contains(.connected) && snapshotCount >= 1
        }

        let connectedCount = statuses.filter { $0 == .connected }.count
        client.stop()
        try expect(statuses.last == .disconnected, "stop should publish a disconnected status")
        client.start()

        try await waitUntil("start after stop should establish a new protocol session") {
            statuses.filter { $0 == .connected }.count > connectedCount && snapshotCount >= 2
        }
    }

    private static func testRendezvousValidationAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-canvas-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard chmod(directory.path, 0o700) == 0 else {
            throw TestFailure("failed to set test directory permissions")
        }

        let file = directory.appendingPathComponent("ipc-rendezvous.json")
        let rendezvous = SesoriRendezvous(
            protocolVersion: sesoriDeviceCanvasProtocolVersion,
            port: 41_234,
            bearerSecret: "test-secret",
            bridgeId: "bridge-a",
            processGeneration: "process-a"
        )
        try JSONEncoder().encode(rendezvous).write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
            throw TestFailure("failed to set test file permissions")
        }

        try expect(
            SesoriRendezvousReader(fileURL: file).read() == rendezvous,
            "owner-only rendezvous should decode"
        )

        guard chmod(file.path, 0o644) == 0 else {
            throw TestFailure("failed to loosen test file permissions")
        }
        try expectThrows("group-readable rendezvous should fail closed") {
            _ = try SesoriRendezvousReader(fileURL: file).read()
        }
        guard chmod(file.path, 0o600) == 0 else {
            throw TestFailure("failed to restore test file permissions")
        }
        do {
            _ = try SesoriRendezvous(
                protocolVersion: 999,
                port: 1,
                bearerSecret: "secret",
                bridgeId: "bridge",
                processGeneration: "process"
            ).validated()
            throw TestFailure("unsupported rendezvous version should fail closed")
        } catch SesoriIntegrationError.unsupportedProtocolVersion {
            // Expected.
        }
    }

    private static func testInboundEncoding() throws {
        let codec = SesoriProtocolCodec()
        let hello = try jsonObject(codec.encodeHello(canvasInstanceId: "canvas-a"))
        try expect(hello["type"] as? String == "hello", "hello type should be explicit")
        try expect(
            hello["protocolVersion"] as? Int == sesoriDeviceCanvasProtocolVersion,
            "hello should carry the current protocol"
        )
        try expect(hello["canvasInstanceId"] as? String == "canvas-a", "hello should carry canvas identity")

        let descriptor = CanvasDeviceDescriptor(
            deviceKey: "ios-00000000-0000-0000-0000-000000000001",
            platform: .ios,
            displayName: "iPhone",
            runtimeDescription: "iOS 27",
            modelDescription: "iPhone",
            dimensions: CanvasDimensions(width: 390, height: 844),
            orientation: .portrait,
            capabilities: .localPresentation
        )
        let inventory = try jsonObject(codec.encodeInventory([descriptor]))
        try expect(inventory["type"] as? String == "inventorySnapshot", "inventory type should be explicit")
        try expect((inventory["devices"] as? [Any])?.count == 1, "inventory should contain its descriptor")
        try expectThrows("duplicate inventory keys should fail closed") {
            _ = try codec.encodeInventory([descriptor, descriptor])
        }
        try expectThrows("oversized inventories should fail locally") {
            _ = try codec.encodeInventory(
                (0...64).map { index in
                    CanvasDeviceDescriptor(
                        deviceKey: "ios-\(index)",
                        platform: .ios,
                        displayName: "iPhone",
                        runtimeDescription: "iOS 27",
                        modelDescription: "iPhone",
                        dimensions: CanvasDimensions(width: 390, height: 844),
                        orientation: .portrait,
                        capabilities: .localPresentation
                    )
                }
            )
        }

        let heartbeat = try jsonObject(
            codec.encodeHeartbeat(canvasInstanceId: "canvas-a", observedAt: 42)
        )
        try expect(heartbeat["type"] as? String == "heartbeat", "heartbeat type should be explicit")
        try expect(heartbeat["observedAt"] as? Int == 42, "heartbeat should carry observed time")
    }

    private static func testOutboundDecoding() throws {
        let codec = SesoriProtocolCodec()
        try expect(
            try codec.decodeOutbound(
                "{\"type\":\"helloAccepted\",\"protocolVersion\":\(sesoriDeviceCanvasProtocolVersion),\"bridgeId\":\"bridge-a\"}"
            ) == .helloAccepted(protocolVersion: sesoriDeviceCanvasProtocolVersion, bridgeId: "bridge-a"),
            "hello acceptance should decode"
        )

        let claimJSON = """
        {"bridgeId":"bridge-a","sessionId":"session-a",\
        "deviceKey":"android-emulator-5554","revision":3,"displayTitle":"Build UI"}
        """
        let snapshot = try codec.decodeOutbound(
            "{\"type\":\"claimsSnapshot\",\"claims\":[\(claimJSON)]}"
        )
        guard case .claimsSnapshot(let claims) = snapshot else {
            throw TestFailure("claims snapshot should decode as its typed case")
        }
        try expect(claims.count == 1, "claims snapshot should preserve claims")
        try expect(claims[0].ownerDisplayTitle == "Build UI", "claim title should decode")

        try expect(
            try codec.decodeOutbound(
                "{\"type\":\"claimRemoved\",\"bridgeId\":\"bridge-a\",\"deviceKey\":\"d\",\"revision\":4}"
            ) == .claimRemoved(bridgeId: "bridge-a", deviceKey: "d", revision: 4),
            "claim removal should decode"
        )
        try expectThrows("unknown outbound message should fail closed") {
            _ = try codec.decodeOutbound("{\"type\":\"futureMessage\"}")
        }
        try expectThrows("invalid claim revision should fail closed") {
            _ = try codec.decodeOutbound(
                "{\"type\":\"claimUpdated\",\"claim\":{\"bridgeId\":\"bridge-a\",\"sessionId\":\"s\",\"deviceKey\":\"d\",\"revision\":0,\"displayTitle\":null}}"
            )
        }
    }

    private static func testSnapshotReplacementAndRevisionFencing() throws {
        var state = SesoriClaimProjectionState()
        try state.begin(bridgeId: "bridge-a")
        let revisionTwo = claim(deviceKey: "android-emulator-5554", revision: 2, title: "Owner A")
        try state.replaceSnapshot([revisionTwo])
        try expect(state.claimsByDeviceKey.count == 1, "snapshot should replace the projection")

        let staleUpdate = claim(deviceKey: revisionTwo.deviceKey, revision: 1, title: "Stale")
        try state.applyUpdate(staleUpdate)
        try expect(
            state.claimsByDeviceKey[revisionTwo.deviceKey]?.ownerDisplayTitle == "Owner A",
            "stale update should not replace a newer projection"
        )
        let renamed = claim(deviceKey: revisionTwo.deviceKey, revision: 2, title: "Owner Renamed")
        try state.applyUpdate(renamed)
        try expect(
            state.claimsByDeviceKey[revisionTwo.deviceKey]?.ownerDisplayTitle == "Owner Renamed",
            "equal-revision metadata updates should refresh the projection"
        )
        try state.applyRemoval(bridgeId: "bridge-a", deviceKey: revisionTwo.deviceKey, revision: 1)
        try expect(
            state.claimsByDeviceKey[revisionTwo.deviceKey] != nil,
            "stale removal should not remove a newer projection"
        )
        try state.applyRemoval(bridgeId: "bridge-a", deviceKey: revisionTwo.deviceKey, revision: 2)
        try expect(state.claimsByDeviceKey.isEmpty, "matching removal should clear the projection")

        let revisionThree = claim(deviceKey: revisionTwo.deviceKey, revision: 3, title: nil)
        try state.applyUpdate(revisionThree)
        try expect(
            state.claimsByDeviceKey[revisionTwo.deviceKey]?.ownerDisplayTitle == "Sesori session",
            "missing title should use the generic fallback"
        )
        try state.replaceSnapshot([])
        try expect(state.claimsByDeviceKey.isEmpty, "reconnect snapshot should replace prior deltas")
        try expectThrows("wrong-bridge update should fail closed") {
            try state.applyUpdate(
                SesoriClaimProjection(
                    bridgeId: "bridge-b",
                    sessionId: "session",
                    deviceKey: "android-emulator-5554",
                    revision: 4,
                    displayTitle: nil
                )
            )
        }
    }

    private static func testDeepLinkEncoding() throws {
        let projection = SesoriClaimProjection(
            bridgeId: "bridge one",
            sessionId: "session/one?#",
            deviceKey: "android-emulator-5554",
            revision: 1,
            displayTitle: nil
        )
        guard let url = SesoriSessionLinkBuilder.url(for: projection),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TestFailure("deep link should build")
        }
        try expect(url.scheme == "com.sesori.app", "deep link should use the Sesori scheme")
        try expect(
            components.percentEncodedPath == "/sessions/session%2Fone%3F%23",
            "canonical session identity should be encoded as one path segment"
        )
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        try expect(query["bridgeId"] == "bridge one", "deep link should carry bridge scope")
        try expect(query["readOnly"] == "false", "deep link should request the editable session")
        try expect(!url.absoluteString.contains(projection.deviceKey), "device key should not be navigation identity")
        try expect(!url.absoluteString.contains("Users"), "deep links should not contain source paths")
    }

    private static func claim(
        deviceKey: String,
        revision: Int,
        title: String?
    ) -> SesoriClaimProjection {
        SesoriClaimProjection(
            bridgeId: "bridge-a",
            sessionId: "session-a",
            deviceKey: deviceKey,
            revision: revision,
            displayTitle: title
        )
    }

    private static func jsonObject(_ frame: String) throws -> [String: Any] {
        guard let data = frame.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure("encoded frame should be a JSON object")
        }
        return object
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw TestFailure(message)
        }
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw TestFailure(message)
    }

    @MainActor
    private static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestFailure(message)
    }
}

private final class MockSesoriWebSocketServer {
    private let bridgeId: String
    private let respondsToHello: Bool
    private let listener: NWListener
    private let queue = DispatchQueue(label: "device-canvas.sesori-integration-tests")
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private var startupError: NWError?
    private var connections: [NWConnection] = []

    init(bridgeId: String, respondsToHello: Bool = true) throws {
        self.bridgeId = bridgeId
        self.respondsToHello = respondsToHello
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() throws -> Int {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                startupSemaphore.signal()
            case .failed(let error):
                startupError = error
                startupSemaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard startupSemaphore.wait(timeout: .now() + 2) == .success else {
            throw TestFailure("mock WebSocket server did not start")
        }
        if let startupError {
            throw startupError
        }
        guard let port = listener.port else {
            throw TestFailure("mock WebSocket server did not bind a port")
        }
        return Int(port.rawValue)
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self,
                  error == nil,
                  let content,
                  let object = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
                  object["type"] as? String == "hello",
                  object["protocolVersion"] as? Int == sesoriDeviceCanvasProtocolVersion else {
                connection.cancel()
                return
            }
            guard respondsToHello else { return }
            send(
                "{\"type\":\"helloAccepted\",\"protocolVersion\":\(sesoriDeviceCanvasProtocolVersion),\"bridgeId\":\"\(bridgeId)\"}",
                to: connection
            ) { [weak self] in
                self?.send("{\"type\":\"claimsSnapshot\",\"claims\":[]}", to: connection)
            }
        }
    }

    private func send(_ frame: String, to connection: NWConnection, completion: (() -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: UUID().uuidString,
            metadata: [metadata]
        )
        connection.send(
            content: frame.data(using: .utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if error == nil {
                    completion?()
                } else {
                    connection.cancel()
                }
            }
        )
    }
}

private struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
