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
        try testStreamCodecAndLimits()
        try await testRemoteStreamClientLifecycle()
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

    private static func testStreamCodecAndLimits() throws {
        let codec = SesoriProtocolCodec()
        let offer = rtcDescription(type: .offer, fingerprintByte: "AA", lineEnding: "\r\n")
        let answer = rtcDescription(type: .answer, fingerprintByte: "BB")
        let candidate = SesoriICECandidate(
            candidate: "candidate:1 1 UDP 1 127.0.0.1 5000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        let turn = SesoriTURNConfiguration(
            urls: ["turn:turn.example.test:3478?transport=udp"],
            username: "user",
            credential: "secret",
            expiresAt: 123
        )
        try expect(turn.isValid, "a canonical TURN URL should be valid")
        try expect(
            SesoriTURNConfiguration(
                urls: [
                    "turn:192.0.2.1:3478?transport=udp",
                    "turns:turn.example.test:5349?transport=tcp",
                    "turn:[2001:db8::1]:3478",
                    "turn:[::]",
                    "turn:[::1]",
                    "TURN:TURN2.EXAMPLE.TEST.:3478?TRANSPORT=UDP",
                    "turns:secure-udp.example.test?transport=udp"
                ],
                username: "user",
                credential: "secret",
                expiresAt: 123
            ).isValid,
            "TURN should accept bounded IP, DNS, UDP, TCP, and TLS URLs"
        )
        for invalidURL in [
            "https://turn.example.test",
            "turn:user@turn.example.test",
            "turn:turn.example.test/path",
            "turn:turn.example.test:0",
            "turn:turn.example.test:65536",
            "turn:999.999.999.999",
            "turn:127.000.000.001",
            "turn:0x7f000001",
            "turn:0x7f.0.0.1",
            "turn:[::ffff:127.0.0.1]",
            "turn:[::ffff:127.000.000.001]",
            "turn:[::ffff:7f00:1]",
            "turn:[::7f00:1]",
            "turn:[::ffff:0:7f00:1]",
            "turn:[2001:db8::192.168.001.001]",
            "turn:turn.example.test?transport=sctp",
            "turn:turn.example.test?transport=udp&debug=true",
            "turn:turn example.test"
        ] {
            try expect(
                !SesoriTURNConfiguration(
                    urls: [invalidURL],
                    username: "user",
                    credential: "secret",
                    expiresAt: 123
                ).isValid,
                "malformed TURN URL should fail closed: \(invalidURL)"
            )
        }
        try expect(
            SesoriTURNConfiguration(
                urls: ["turn:turn.example.test"],
                username: String(repeating: "u", count: 509),
                credential: "secret",
                expiresAt: 123
            ).isValid,
            "TURN usernames at WebRTC's byte limit should remain valid"
        )
        try expect(
            !SesoriTURNConfiguration(
                urls: [
                    "turn:turn.example.test",
                    "TURN:TURN.EXAMPLE.TEST.:03478?TRANSPORT=UDP"
                ],
                username: "user",
                credential: "secret",
                expiresAt: 123
            ).isValid,
            "semantically duplicate TURN URLs should fail closed"
        )
        try expect(
            !SesoriTURNConfiguration(
                urls: ["turn:turn.example.test"],
                username: String(repeating: "u", count: 510),
                credential: "secret",
                expiresAt: 123
            ).isValid,
            "TURN usernames beyond WebRTC's byte limit should fail closed"
        )
        let requestFrame = streamStartFrame(
            requestId: "request-a",
            leaseId: "lease-a",
            control: false,
            offer: offer,
            iceCandidates: [candidate],
            turn: turn
        )
        try expect(
            try codec.decodeOutbound(requestFrame) == .streamStart(
                SesoriStreamStartRequest(
                    requestId: "request-a",
                    leaseId: "lease-a",
                    bridgeId: "bridge-a",
                    sessionId: "session-a",
                    deviceKey: "android-emulator-5554",
                    claimRevision: 3,
                    expiresAt: 4_000_000_000_000,
                    control: false,
                    offer: offer,
                    iceCandidates: [candidate],
                    turn: turn
                )
            ),
            "stream start should decode all signaling fields"
        )
        try expect(
            turn.canonicalURLs == ["turn:turn.example.test:3478?transport=udp"],
            "validated TURN URLs should expose their libwebrtc-compatible form"
        )
        let noTURNFrame = streamStartFrame(
            requestId: "request-no-turn",
            leaseId: "lease-no-turn",
            control: false,
            offer: offer,
            iceCandidates: [],
            turn: nil
        )
        guard case .streamStart(let noTURNRequest) = try codec.decodeOutbound(noTURNFrame) else {
            throw TestFailure("stream start without TURN should decode")
        }
        try expect(noTURNRequest.turn == nil, "omitted TURN should remain absent")
        try expect(
            try codec.decodeOutbound(
                malformedTurnFrame(
                    requestId: "request-malformed-shape",
                    leaseId: "lease-malformed-shape",
                    offer: offer
                )
            ) == .invalidStreamStart(
                requestId: "request-malformed-shape",
                leaseId: "lease-malformed-shape"
            ),
            "decodable correlation should isolate a malformed TURN object"
        )
        try expect(
            try codec.decodeOutbound(
                "{\"type\":\"streamRevoke\",\"leaseId\":\"lease-a\",\"reason\":\"claimChanged\"}"
            ) == .streamRevoke(leaseId: "lease-a", reason: .claimChanged),
            "stream revoke should decode its lease and reason"
        )

        let started = try jsonObject(
            codec.encodeStreamStarted(
                requestId: "request-a",
                leaseId: "lease-a",
                answer: answer,
                iceCandidates: [candidate]
            )
        )
        try expect(
            Set(started.keys) == ["type", "requestId", "leaseId", "answer", "iceCandidates"],
            "stream started should use the exact bridge fields"
        )
        try expect(started["type"] as? String == "streamStarted", "stream started type should match")
        try expect(started["requestId"] as? String == "request-a", "stream started should correlate request")
        try expect(started["leaseId"] as? String == "lease-a", "stream started should correlate lease")

        let failed = try jsonObject(
            codec.encodeStreamStartFailed(
                requestId: "request-a",
                leaseId: "lease-a",
                reason: .invalidOffer
            )
        )
        try expect(
            failed as NSDictionary == [
                "type": "streamStartFailed",
                "requestId": "request-a",
                "leaseId": "lease-a",
                "reason": "invalidOffer"
            ] as NSDictionary,
            "stream failure JSON should exactly match the bridge contract"
        )
        let closed = try jsonObject(codec.encodeStreamClosed(leaseId: "lease-a", reason: .failed))
        try expect(
            closed as NSDictionary == [
                "type": "streamClosed",
                "leaseId": "lease-a",
                "reason": "failed"
            ] as NSDictionary,
            "stream closure JSON should exactly match the bridge contract"
        )

        try expect(offer.isValid, "CRLF SDP with one matching fingerprint should be valid")
        let mismatch = SesoriRTCDescription(
            type: .offer,
            sdp: offer.sdp,
            fingerprint: "sha-256 " + Array(repeating: "AB", count: 32).joined(separator: ":")
        )
        try expect(!mismatch.isValid, "fingerprint metadata must exactly match SDP")
        let duplicate = SesoriRTCDescription(
            type: .offer,
            sdp: offer.sdp + "a=fingerprint:\(offer.fingerprint)\n",
            fingerprint: offer.fingerprint
        )
        try expect(!duplicate.isValid, "SDP must contain exactly one fingerprint line")
        let loneCR = SesoriRTCDescription(
            type: .offer,
            sdp: offer.sdp.replacingOccurrences(of: "\r\n", with: "\r"),
            fingerprint: offer.fingerprint
        )
        try expect(!loneCR.isValid, "SDP should only accept LF and CRLF line endings")
        try expectThrows("answer encoder must reject an offer") {
            _ = try codec.encodeStreamStarted(
                requestId: "request-a",
                leaseId: "lease-a",
                answer: offer,
                iceCandidates: []
            )
        }
        try expect(
            try codec.decodeOutbound(
                streamStartFrame(
                    requestId: "request-a",
                    leaseId: "lease-a",
                    control: false,
                    offer: offer,
                    iceCandidates: Array(repeating: candidate, count: 65),
                    turn: turn
                )
            ) == .invalidStreamStart(requestId: "request-a", leaseId: "lease-a"),
            "too many candidates should reject only their correlated stream"
        )
        let oversized = SesoriRTCDescription(
            type: .offer,
            sdp: String(repeating: "x", count: 262_145),
            fingerprint: offer.fingerprint
        )
        try expect(
            try codec.decodeOutbound(
                streamStartFrame(
                    requestId: "request-a",
                    leaseId: "lease-a",
                    control: false,
                    offer: oversized,
                    iceCandidates: [],
                    turn: turn
                )
            ) == .invalidStreamStart(requestId: "request-a", leaseId: "lease-a"),
            "oversized SDP should reject only its correlated stream"
        )
        try expectThrows("unknown revoke reason should fail closed") {
            _ = try codec.decodeOutbound(
                "{\"type\":\"streamRevoke\",\"leaseId\":\"lease-a\",\"reason\":\"futureReason\"}"
            )
        }
    }

    @MainActor
    private static func testRemoteStreamClientLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-canvas-stream-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard chmod(directory.path, 0o700) == 0 else {
            throw TestFailure("failed to set stream test directory permissions")
        }

        let claimJSON = """
        {"bridgeId":"bridge-a","sessionId":"session-a",\
        "deviceKey":"android-emulator-5554","revision":3,"displayTitle":"Stream test"}
        """
        let server = try MockSesoriWebSocketServer(
            bridgeId: "bridge-a",
            claimsJSON: "[\(claimJSON)]"
        )
        let serverPort = try server.start()
        defer { server.stop() }
        let file = directory.appendingPathComponent("ipc-rendezvous.json")
        try JSONEncoder().encode(
            SesoriRendezvous(
                protocolVersion: sesoriDeviceCanvasProtocolVersion,
                port: serverPort,
                bearerSecret: "stream-secret",
                bridgeId: "bridge-a",
                processGeneration: "stream-process"
            )
        ).write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
            throw TestFailure("failed to set stream rendezvous permissions")
        }

        let handler = FakeRemoteStreamHandler()
        let sendGate = StreamStartedSendGate()
        defer { sendGate.releaseWithFailure() }
        var statuses: [SesoriIntegrationStatus] = []
        let client = SesoriIntegrationClient(
            rendezvousURL: file,
            remoteStreams: handler,
            onStatusChanged: { statuses.append($0) },
            onClaimsChanged: { _ in },
            socketSender: { socket, message in
                try await sendGate.send(socket: socket, message: message)
            }
        )
        client.updateInventory([
            CanvasDeviceDescriptor(
                deviceKey: "android-emulator-5554",
                platform: .android,
                displayName: "Pixel",
                runtimeDescription: "Android 16",
                modelDescription: "Pixel",
                dimensions: CanvasDimensions(width: 1080, height: 2400),
                orientation: .portrait,
                capabilities: .androidRemoteVideo
            )
        ])
        client.start()
        defer { client.stop() }
        try await waitUntil("stream client should complete its handshake") {
            statuses.contains(.connected)
        }
        let hello = server.messages(ofType: "hello").first
        let advertised = hello?["capabilities"] as? [String: Any]
        try expect(advertised?["remoteVideo"] as? Bool == true, "hello should advertise handler video")
        try expect(advertised?["remoteControl"] as? Bool == false, "hello should advertise no control")

        let offer = rtcDescription(type: .offer, fingerprintByte: "AA")
        let answer = rtcDescription(type: .answer, fingerprintByte: "BB")
        let turn = SesoriTURNConfiguration(
            urls: ["turn:turn.example.test"],
            username: "user",
            credential: "secret",
            expiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
        )

        server.sendToAll(
            malformedTurnFrame(
                requestId: "request-malformed-turn",
                leaseId: "lease-malformed-turn",
                offer: offer
            )
        )
        try await waitUntil("malformed TURN should fail only its correlated stream") {
            server.messages(ofType: "streamStartFailed").contains {
                $0["requestId"] as? String == "request-malformed-turn"
                    && $0["leaseId"] as? String == "lease-malformed-turn"
                    && $0["reason"] as? String == "peerSetupFailed"
            }
        }
        try expect(handler.requests.isEmpty, "malformed TURN must not reach the stream handler")
        try expect(statuses.last == .connected, "malformed TURN must not disconnect the protocol")

        let connectedCountBeforeCollision = statuses.filter { $0 == .connected }.count
        let disconnectedCountBeforeCollision = statuses.filter { $0 == .disconnected }.count
        let closeAllCountBeforeCollision = handler.closeAllCount
        server.sendToAll(
            streamStartFrame(
                requestId: "request-collision",
                leaseId: "lease-collision",
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("collision stream should remain pending") {
            handler.requests.contains { $0.leaseId == "lease-collision" }
        }
        server.sendToAll(
            malformedTurnFrame(
                requestId: "request-collision",
                leaseId: "lease-collision",
                offer: offer
            )
        )
        try await waitUntil("duplicate correlation should fence the protocol connection") {
            statuses.filter { $0 == .disconnected }.count > disconnectedCountBeforeCollision
                && handler.closeAllCount == closeAllCountBeforeCollision + 1
        }
        try expect(
            !server.messages(ofType: "streamStartFailed").contains {
                $0["leaseId"] as? String == "lease-collision"
            } && !server.messages(ofType: "streamStarted").contains {
                $0["leaseId"] as? String == "lease-collision"
            },
            "ambiguous duplicate correlation must not emit contradictory terminal messages"
        )
        try await waitUntil("the client should reconnect after a correlation violation") {
            statuses.filter { $0 == .connected }.count > connectedCountBeforeCollision
        }

        server.sendToAll(
            streamStartFrame(
                requestId: "request-control",
                leaseId: "lease-control",
                control: true,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("unsupported control should receive a correlated failure") {
            server.messages(ofType: "streamStartFailed").contains {
                $0["requestId"] as? String == "request-control"
                    && $0["leaseId"] as? String == "lease-control"
                    && $0["reason"] as? String == "unsupported"
            }
        }
        try expect(
            !handler.requests.contains { $0.leaseId == "lease-control" },
            "unsupported control must not reach the handler"
        )

        server.sendToAll(
            streamStartFrame(
                requestId: "request-invalid",
                leaseId: "lease-invalid",
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("structurally valid offer should reach the handler") {
            handler.requests.contains { $0.leaseId == "lease-invalid" }
        }
        handler.complete(leaseId: "lease-invalid", with: .failed(.invalidOffer))
        try await waitUntil("handler offer rejection should retain invalidOffer") {
            server.messages(ofType: "streamStartFailed").contains {
                $0["requestId"] as? String == "request-invalid"
                    && $0["leaseId"] as? String == "lease-invalid"
                    && $0["reason"] as? String == "invalidOffer"
            }
        }

        let connectedCountAfterFailure = statuses.filter { $0 == .connected }.count
        let disconnectedCountAfterFailure = statuses.filter { $0 == .disconnected }.count
        let failedCorrelationRequestCount = handler.requests.filter {
            $0.leaseId == "lease-invalid"
        }.count
        server.sendToAll(
            streamStartFrame(
                requestId: "request-invalid",
                leaseId: "lease-invalid",
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("completed failure correlation should remain reserved") {
            statuses.filter { $0 == .disconnected }.count > disconnectedCountAfterFailure
        }
        try expect(
            handler.requests.filter { $0.leaseId == "lease-invalid" }.count
                == failedCorrelationRequestCount,
            "a completed failure correlation must not start replacement media"
        )
        try await waitUntil("the client should reconnect after terminal correlation reuse") {
            statuses.filter { $0 == .connected }.count > connectedCountAfterFailure
        }

        server.sendToAll(
            streamStartFrame(
                requestId: "request-success",
                leaseId: "lease-success",
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("supported stream should begin setup without blocking receive") {
            handler.requests.contains { $0.leaseId == "lease-success" }
        }
        handler.complete(
            leaseId: "lease-success",
            with: .started(answer: answer, iceCandidates: [])
        )
        try await waitUntil("successful setup should preserve request and lease correlation") {
            server.messages(ofType: "streamStarted").contains {
                $0["requestId"] as? String == "request-success"
                    && $0["leaseId"] as? String == "lease-success"
            }
        }
        handler.reportClosed(leaseId: "lease-success", reason: .stopped)
        try await waitUntil("active handler closure should be reported once") {
            server.messages(ofType: "streamClosed").filter {
                $0["leaseId"] as? String == "lease-success"
            }.count == 1
        }
        handler.reportClosed(leaseId: "lease-success", reason: .failed)
        try await Task.sleep(for: .milliseconds(100))
        try expect(
            server.messages(ofType: "streamClosed").filter {
                $0["leaseId"] as? String == "lease-success"
            }.count == 1,
            "stale closure callbacks should be suppressed"
        )

        let connectedCountAfterClosure = statuses.filter { $0 == .connected }.count
        let disconnectedCountAfterClosure = statuses.filter { $0 == .disconnected }.count
        let closedCorrelationRequestCount = handler.requests.filter {
            $0.leaseId == "lease-success"
        }.count
        server.sendToAll(
            streamStartFrame(
                requestId: "request-success",
                leaseId: "lease-success",
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("completed closure correlation should remain reserved") {
            statuses.filter { $0 == .disconnected }.count > disconnectedCountAfterClosure
        }
        try expect(
            handler.requests.filter { $0.leaseId == "lease-success" }.count
                == closedCorrelationRequestCount,
            "a completed closure correlation must not start replacement media"
        )
        try await waitUntil("the client should reconnect after closed correlation reuse") {
            statuses.filter { $0 == .connected }.count > connectedCountAfterClosure
        }

        server.sendToAll(
            streamStartFrame(
                requestId: "request-pending",
                leaseId: "lease-pending",
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("pending stream should reach the handler") {
            handler.requests.contains { $0.leaseId == "lease-pending" }
        }
        server.sendToAll(
            "{\"type\":\"streamRevoke\",\"leaseId\":\"lease-pending\",\"reason\":\"clientDisconnected\"}"
        )
        try await waitUntil("revoke while pending should fail setup exactly once") {
            server.messages(ofType: "streamStartFailed").filter {
                $0["requestId"] as? String == "request-pending"
                    && $0["leaseId"] as? String == "lease-pending"
                    && $0["reason"] as? String == "peerSetupFailed"
            }.count == 1
        }
        try expect(
            handler.revocations.contains {
                $0.leaseId == "lease-pending" && $0.reason == .clientDisconnected
            },
            "pending revoke should reach the handler"
        )
        handler.complete(
            leaseId: "lease-pending",
            with: .started(answer: answer, iceCandidates: [])
        )
        try await Task.sleep(for: .milliseconds(100))
        try expect(
            !server.messages(ofType: "streamStarted").contains {
                $0["leaseId"] as? String == "lease-pending"
            },
            "completion after revoke must not send stale success"
        )

        let pendingExpiry = Int64(Date().timeIntervalSince1970 * 1_000) + 1_000
        server.sendToAll(
            streamStartFrame(
                requestId: "request-expiring-pending",
                leaseId: "lease-expiring-pending",
                expiresAt: pendingExpiry,
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("expiring pending stream should reach the handler") {
            handler.requests.contains { $0.leaseId == "lease-expiring-pending" }
        }
        try await waitUntil("pending lease deadline should settle setup") {
            server.messages(ofType: "streamStartFailed").contains {
                $0["requestId"] as? String == "request-expiring-pending"
                    && $0["leaseId"] as? String == "lease-expiring-pending"
            }
        }
        try expect(
            handler.revocations.contains {
                $0.leaseId == "lease-expiring-pending" && $0.reason == .expired
            },
            "pending lease deadline should revoke the handler"
        )

        let activeExpiry = Int64(Date().timeIntervalSince1970 * 1_000) + 1_200
        server.sendToAll(
            streamStartFrame(
                requestId: "request-expiring-active",
                leaseId: "lease-expiring-active",
                expiresAt: activeExpiry,
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("expiring active stream should reach the handler") {
            handler.requests.contains { $0.leaseId == "lease-expiring-active" }
        }
        handler.complete(
            leaseId: "lease-expiring-active",
            with: .started(answer: answer, iceCandidates: [])
        )
        try await waitUntil("expiring stream should become active before its deadline") {
            server.messages(ofType: "streamStarted").contains {
                $0["leaseId"] as? String == "lease-expiring-active"
            }
        }
        try await waitUntil("active lease deadline should revoke the handler") {
            handler.revocations.contains {
                $0.leaseId == "lease-expiring-active" && $0.reason == .expired
            }
        }

        let turnExpiry = Int64(Date().timeIntervalSince1970 * 1_000) + 1_500
        let expiringTurn = SesoriTURNConfiguration(
            urls: ["turns:turn.example.test:5349?transport=tcp"],
            username: "user",
            credential: "secret",
            expiresAt: turnExpiry
        )
        server.sendToAll(
            streamStartFrame(
                requestId: "request-expiring-turn",
                leaseId: "lease-expiring-turn",
                expiresAt: turnExpiry + 10_000,
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: expiringTurn
            )
        )
        try await waitUntil("credential-expiring stream should reach the handler") {
            handler.requests.contains { $0.leaseId == "lease-expiring-turn" }
        }
        handler.complete(
            leaseId: "lease-expiring-turn",
            with: .started(answer: answer, iceCandidates: [])
        )
        try await waitUntil("credential-expiring stream should become active") {
            server.messages(ofType: "streamStarted").contains {
                $0["leaseId"] as? String == "lease-expiring-turn"
            }
        }
        try await waitUntil("TURN credential deadline should revoke the handler") {
            handler.revocations.contains {
                $0.leaseId == "lease-expiring-turn" && $0.reason == .expired
            }
        }

        let connectedCountBeforeSendingExpiry = statuses.filter { $0 == .connected }.count
        let disconnectedCountBeforeSendingExpiry = statuses.filter { $0 == .disconnected }.count
        let sendingExpiry = Int64(Date().timeIntervalSince1970 * 1_000) + 1_200
        sendGate.blockStreamStarted(leaseId: "lease-expiring-send")
        server.sendToAll(
            streamStartFrame(
                requestId: "request-expiring-send",
                leaseId: "lease-expiring-send",
                expiresAt: sendingExpiry,
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("send-race stream should reach the handler") {
            handler.requests.contains { $0.leaseId == "lease-expiring-send" }
        }
        handler.complete(
            leaseId: "lease-expiring-send",
            with: .started(answer: answer, iceCandidates: [])
        )
        try await waitUntil("streamStarted send should enter the deterministic gate") {
            sendGate.enteredLeaseIds.contains("lease-expiring-send")
        }
        try await waitUntil("credential expiry should revoke an in-flight success send") {
            handler.revocations.contains {
                $0.leaseId == "lease-expiring-send" && $0.reason == .expired
            }
        }
        try await waitUntil("in-flight expiry should terminate the ambiguous protocol connection") {
            statuses.filter { $0 == .disconnected }.count > disconnectedCountBeforeSendingExpiry
        }
        try await waitUntil("expiry should cancel the in-flight success task") {
            sendGate.cancelledLeaseIds.contains("lease-expiring-send")
        }
        try await Task.sleep(for: .milliseconds(150))
        try expect(
            !server.messages(ofType: "streamStarted").contains {
                $0["leaseId"] as? String == "lease-expiring-send"
            },
            "expiry during an in-flight send must not deliver stale streamStarted"
        )
        try await waitUntil("the client should reconnect after fencing the ambiguous send") {
            statuses.filter { $0 == .connected }.count > connectedCountBeforeSendingExpiry
        }

        let closeAllCountBeforeStop = handler.closeAllCount
        server.sendToAll(
            streamStartFrame(
                requestId: "request-disconnect",
                leaseId: "lease-disconnect",
                control: false,
                offer: offer,
                iceCandidates: [],
                turn: turn
            )
        )
        try await waitUntil("disconnect test stream should remain pending") {
            handler.requests.contains { $0.leaseId == "lease-disconnect" }
        }
        client.stop()
        try expect(
            handler.closeAllCount == closeAllCountBeforeStop + 1,
            "disconnect should close pending and active streams"
        )
        handler.complete(
            leaseId: "lease-disconnect",
            with: .started(answer: answer, iceCandidates: [])
        )
        try await Task.sleep(for: .milliseconds(100))
        try expect(
            !server.messages(ofType: "streamStarted").contains {
                $0["leaseId"] as? String == "lease-disconnect"
            },
            "completion after disconnect must be fenced"
        )
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

    private static func rtcDescription(
        type: SesoriRTCDescriptionType,
        fingerprintByte: String,
        lineEnding: String = "\n"
    ) -> SesoriRTCDescription {
        let fingerprint = "sha-256 "
            + Array(repeating: fingerprintByte, count: 32).joined(separator: ":")
        return SesoriRTCDescription(
            type: type,
            sdp: "v=0\(lineEnding)a=fingerprint:\(fingerprint)\(lineEnding)",
            fingerprint: fingerprint
        )
    }

    private static func streamStartFrame(
        requestId: String,
        leaseId: String,
        expiresAt: Int64 = 4_000_000_000_000,
        control: Bool,
        offer: SesoriRTCDescription,
        iceCandidates: [SesoriICECandidate],
        turn: SesoriTURNConfiguration?
    ) -> String {
        let request = SesoriStreamStartRequest(
            requestId: requestId,
            leaseId: leaseId,
            bridgeId: "bridge-a",
            sessionId: "session-a",
            deviceKey: "android-emulator-5554",
            claimRevision: 3,
            expiresAt: expiresAt,
            control: control,
            offer: offer,
            iceCandidates: iceCandidates,
            turn: turn
        )
        let encoded = try! JSONEncoder().encode(request)
        var object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["type"] = "streamStart"
        let frame = try! JSONSerialization.data(withJSONObject: object)
        return String(data: frame, encoding: .utf8)!
    }

    private static func malformedTurnFrame(
        requestId: String,
        leaseId: String,
        offer: SesoriRTCDescription
    ) -> String {
        let validFrame = streamStartFrame(
            requestId: requestId,
            leaseId: leaseId,
            control: false,
            offer: offer,
            iceCandidates: [],
            turn: nil
        )
        let data = validFrame.data(using: .utf8)!
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["turn"] = [
            "urls": "turn:turn.example.test",
            "username": "user",
            "credential": "secret",
            "expiresAt": 4_000_000_000_000
        ]
        let malformed = try! JSONSerialization.data(withJSONObject: object)
        return String(data: malformed, encoding: .utf8)!
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

@MainActor
private final class FakeRemoteStreamHandler: SesoriRemoteStreamHandling {
    let capabilities = CanvasCapabilities.androidRemoteVideo
    private(set) var requests: [SesoriStreamStartRequest] = []
    private(set) var revocations: [(leaseId: String, reason: SesoriStreamRevokeReason)] = []
    private(set) var closeAllCount = 0

    private var continuations: [
        String: CheckedContinuation<SesoriRemoteStreamStartResult, Never>
    ] = [:]
    private var closedHandler: @MainActor (String, SesoriStreamClosedReason) -> Void = { _, _ in }

    func startStream(_ request: SesoriStreamStartRequest) async -> SesoriRemoteStreamStartResult {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            continuations[request.leaseId] = continuation
        }
    }

    func revokeStream(leaseId: String, reason: SesoriStreamRevokeReason) {
        revocations.append((leaseId, reason))
        continuations.removeValue(forKey: leaseId)?.resume(returning: .failed(.peerSetupFailed))
    }

    func closeAllStreams() {
        closeAllCount += 1
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: .failed(.peerSetupFailed))
        }
    }

    func setStreamClosedHandler(
        _ handler: @escaping @MainActor (String, SesoriStreamClosedReason) -> Void
    ) {
        closedHandler = handler
    }

    func complete(leaseId: String, with result: SesoriRemoteStreamStartResult) {
        continuations.removeValue(forKey: leaseId)?.resume(returning: result)
    }

    func reportClosed(leaseId: String, reason: SesoriStreamClosedReason) {
        closedHandler(leaseId, reason)
    }
}

@MainActor
private final class StreamStartedSendGate {
    private(set) var enteredLeaseIds: Set<String> = []
    private(set) var cancelledLeaseIds: Set<String> = []

    private var blockedLeaseId: String?
    private var continuation: CheckedContinuation<Void, Error>?

    func blockStreamStarted(leaseId: String) {
        blockedLeaseId = leaseId
    }

    func send(
        socket: URLSessionWebSocketTask,
        message: URLSessionWebSocketTask.Message
    ) async throws {
        if case .string(let frame) = message,
           let data = frame.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["type"] as? String == "streamStarted",
           let leaseId = object["leaseId"] as? String,
           leaseId == blockedLeaseId {
            enteredLeaseIds.insert(leaseId)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelBlockedSend(leaseId: leaseId)
                }
            }
            return
        }
        try await socket.send(message)
    }

    func releaseWithFailure() {
        blockedLeaseId = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: URLError(.cancelled))
    }

    private func cancelBlockedSend(leaseId: String) {
        guard blockedLeaseId == leaseId else { return }
        blockedLeaseId = nil
        cancelledLeaseIds.insert(leaseId)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private final class MockSesoriWebSocketServer {
    private let bridgeId: String
    private let respondsToHello: Bool
    private let claimsJSON: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "device-canvas.sesori-integration-tests")
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private var startupError: NWError?
    private var connections: [NWConnection] = []
    private var receivedMessages: [[String: Any]] = []

    init(
        bridgeId: String,
        respondsToHello: Bool = true,
        claimsJSON: String = "[]"
    ) throws {
        self.bridgeId = bridgeId
        self.respondsToHello = respondsToHello
        self.claimsJSON = claimsJSON
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

    func sendToAll(_ frame: String) {
        queue.async { [weak self] in
            guard let self else { return }
            connections.forEach { self.send(frame, to: $0) }
        }
    }

    func messages(ofType type: String) -> [[String: Any]] {
        queue.sync {
            receivedMessages.filter { $0["type"] as? String == type }
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveNextMessage(from: connection)
    }

    private func receiveNextMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self,
                   error == nil,
                   let content,
                  let object = try? JSONSerialization.jsonObject(with: content) as? [String: Any] else {
                connection.cancel()
                return
            }
            receivedMessages.append(object)
            if object["type"] as? String == "hello" {
                guard object["protocolVersion"] as? Int == sesoriDeviceCanvasProtocolVersion else {
                    connection.cancel()
                    return
                }
                if respondsToHello {
                    send(
                        "{\"type\":\"helloAccepted\",\"protocolVersion\":\(sesoriDeviceCanvasProtocolVersion),\"bridgeId\":\"\(bridgeId)\"}",
                        to: connection
                    ) { [weak self] in
                        guard let self else { return }
                        send(
                            "{\"type\":\"claimsSnapshot\",\"claims\":\(claimsJSON)}",
                            to: connection
                        )
                    }
                }
            }
            receiveNextMessage(from: connection)
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
