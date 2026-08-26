import AppKit
import CoreVideo
import Darwin
import Foundation
@preconcurrency import WebRTC

@main
private enum AndroidWebRTCStreamTests {
    private static let deviceKey = "android-emulator-5554"
    fileprivate static let callbackTimeoutNanoseconds: UInt64 = 5_000_000_000

    @MainActor
    static func main() async {
        do {
            let ranLiveSmoke = try await run()
            if !ranLiveSmoke {
                print("Android WebRTC native integration tests passed")
            }
        } catch {
            let message = "Android WebRTC native integration tests failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() async throws -> Bool {
        let service = AndroidWebRTCService()
        let endpoint = AndroidEmulatorStreamEndpoint(serial: "emulator-5554")
        let closedStreams = ClosedStreamRecorder()
        service.setStreamClosedHandler { leaseId, reason in
            closedStreams.record(leaseId: leaseId, reason: reason)
        }
        service.register(endpoint: endpoint, for: deviceKey)

        var offererFactory: RTCPeerConnectionFactory? = RTCPeerConnectionFactory()
        guard let factory = offererFactory else {
            throw TestFailure("failed to create the M151 offerer factory")
        }
        var firstOfferer: LocalOfferer?
        var secondOfferer: LocalOfferer?
        defer {
            service.closeAllStreams()
            firstOfferer?.close()
            secondOfferer?.close()
            offererFactory = nil
        }

        let first = try await LocalOfferer.create(factory: factory)
        firstOfferer = first

        let controlResult = try await bounded("control start", seconds: 12) {
            await service.startStream(
                request(
                    leaseId: "lease-control",
                    requestId: "request-control",
                    control: true,
                    offer: first.offer,
                    candidates: first.candidates
                )
            )
        }
        try expectFailure(controlResult, equals: .unsupported, "control must be unsupported")

        let firstResult = try await bounded("first stream start", seconds: 12) {
            await service.startStream(
                request(
                    leaseId: "lease-one",
                    requestId: "request-one",
                    control: false,
                    offer: first.offer,
                    candidates: first.candidates
                )
            )
        }
        let firstAnswer = try startedValue(firstResult, label: "first stream")
        try validate(answer: firstAnswer.answer, candidates: firstAnswer.candidates)
        try await first.apply(
            answer: firstAnswer.answer,
            candidates: firstAnswer.candidates
        )
        try await first.waitForICEConnection()

        service.unregisterEndpoint(for: deviceKey)
        try await Task.sleep(for: .milliseconds(250))
        let firstLeaseCloseEvents = closedStreams.events(for: "lease-one")
        first.close()
        firstOfferer = nil

        service.register(endpoint: endpoint, for: deviceKey)
        let second = try await LocalOfferer.create(factory: factory)
        secondOfferer = second
        let secondResult = try await bounded("second stream start", seconds: 12) {
            await service.startStream(
                request(
                    leaseId: "lease-two",
                    requestId: "request-two",
                    control: false,
                    offer: second.offer,
                    candidates: second.candidates
                )
            )
        }
        let secondAnswer = try startedValue(secondResult, label: "second stream")
        try validate(answer: secondAnswer.answer, candidates: secondAnswer.candidates)
        try await second.apply(
            answer: secondAnswer.answer,
            candidates: secondAnswer.candidates
        )
        try await second.waitForICEConnection()

        service.revokeStream(leaseId: "lease-two", reason: .stopped)
        try await Task.sleep(for: .milliseconds(300))
        try expect(
            closedStreams.count(for: "lease-two") == 0,
            "intentional revoke must not emit streamClosed"
        )
        try expect(
            closedStreams.events(for: "lease-one") == firstLeaseCloseEvents,
            "later cleanup must not duplicate the first lease callback"
        )
        second.close()
        secondOfferer = nil

        var ranLiveSmoke = false
        if let serial = ProcessInfo.processInfo.environment["DEVICE_CANVAS_ANDROID_SERIAL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            ranLiveSmoke = true
            let summary = try await runLiveSmoke(
                serial: serial,
                service: service,
                factory: factory
            )
            print(
                "remoteFrames=\(summary.remoteFrameCount) "
                    + "remoteDimensions=\(summary.remoteWidth)x\(summary.remoteHeight) "
                    + "localDimensions=\(summary.local.width)x\(summary.local.height) "
                    + "localPlanes=\(summary.local.planes.count)"
            )
        }

        try expect(
            firstLeaseCloseEvents == [.stopped],
            "unregister must report exactly one stopped callback for the first lease"
        )
        return ranLiveSmoke
    }

    @MainActor
    private static func runLiveSmoke(
        serial: String,
        service: AndroidWebRTCService,
        factory: RTCPeerConnectionFactory
    ) async throws -> LiveSmokeSummary {
        let liveDeviceKey = "android-\(serial)"
        let leaseId = "lease-live-smoke"
        try await Task.detached(priority: .utility) {
            _ = try AndroidSDK.runADB([
                "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"
            ])
        }.value
        let endpoint = AndroidEmulatorStreamEndpoint(serial: serial)
        service.register(endpoint: endpoint, for: liveDeviceKey)

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let screenView = AndroidEmulatorScreenView(serial: serial, frameSink: endpoint)
        screenView.frame = window.contentView?.bounds ?? window.contentLayoutRect
        screenView.autoresizingMask = [.width, .height]
        window.contentView = screenView
        window.orderFront(nil)
        let initialStimulation = Task {
            try await stimulateLiveEmulator(serial: serial)
        }

        let renderer = CountingVideoRenderer()
        var offerer: LocalOfferer?
        var streamIsActive = false
        var screenIsStopped = false
        defer {
            if streamIsActive {
                service.revokeStream(leaseId: leaseId, reason: .stopped)
            }
            offerer?.close()
            if !screenIsStopped {
                screenView.stop()
            }
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            service.unregisterEndpoint(for: liveDeviceKey)
            initialStimulation.cancel()
        }

        var localMetadata: PixelBufferMetadata?
        try await waitUntil("local emulator display frame", seconds: 20) {
            guard let pixelBuffer = screenView.displayedPixelBuffer() else { return false }
            localMetadata = PixelBufferMetadata(pixelBuffer)
            return true
        }
        guard let localMetadata else {
            throw TestFailure("local emulator display metadata was unavailable")
        }
        try await initialStimulation.value

        let liveOfferer = try await LocalOfferer.create(factory: factory)
        offerer = liveOfferer
        let result = try await bounded("live stream start", seconds: 12) {
            await service.startStream(
                SesoriStreamStartRequest(
                    requestId: "request-live-smoke",
                    leaseId: leaseId,
                    bridgeId: "bridge-live-smoke",
                    sessionId: "session-live-smoke",
                    deviceKey: liveDeviceKey,
                    claimRevision: 1,
                    expiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 300_000,
                    control: false,
                    offer: liveOfferer.offer,
                    iceCandidates: liveOfferer.candidates,
                    turn: nil
                )
            )
        }
        let started = try startedValue(result, label: "live stream")
        streamIsActive = true
        try validate(answer: started.answer, candidates: started.candidates)
        try await liveOfferer.apply(answer: started.answer, candidates: started.candidates)
        try liveOfferer.attach(renderer: renderer)
        try await liveOfferer.waitForICEConnection()

        try await stimulateLiveEmulator(serial: serial)
        let frameDeadline = Date().addingTimeInterval(30)
        while renderer.snapshot.frameCount < 30, Date() < frameDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(
            renderer.snapshot.frameCount >= 30,
            "remote frame count remained at \(renderer.snapshot.frameCount)"
        )

        service.revokeStream(leaseId: leaseId, reason: .stopped)
        streamIsActive = false
        try await Task.sleep(for: .milliseconds(500))
        let afterDrain = renderer.snapshot.frameCount
        try await Task.sleep(for: .milliseconds(750))
        let finalSnapshot = renderer.snapshot
        try expect(
            finalSnapshot.frameCount <= afterDrain + 2,
            "remote frames must stop after stream revoke"
        )

        screenView.stop()
        screenIsStopped = true
        return LiveSmokeSummary(
            remoteFrameCount: finalSnapshot.frameCount,
            remoteWidth: finalSnapshot.width,
            remoteHeight: finalSnapshot.height,
            local: localMetadata
        )
    }

    private static func stimulateLiveEmulator(serial: String) async throws {
        try await Task.detached(priority: .utility) {
            let collapse = ["-s", serial, "shell", "cmd", "statusbar", "collapse"]
            defer { _ = try? AndroidSDK.runADB(collapse) }
            for _ in 0..<8 {
                _ = try AndroidSDK.runADB([
                    "-s", serial, "shell", "input", "keyevent", "KEYCODE_APP_SWITCH"
                ])
                try await Task.sleep(for: .milliseconds(400))
                _ = try AndroidSDK.runADB([
                    "-s", serial, "shell", "input", "keyevent", "KEYCODE_HOME"
                ])
                try await Task.sleep(for: .milliseconds(400))
                _ = try AndroidSDK.runADB([
                    "-s", serial, "shell", "cmd", "statusbar", "expand-notifications"
                ])
                try await Task.sleep(for: .milliseconds(600))
                _ = try AndroidSDK.runADB(collapse)
                try await Task.sleep(for: .milliseconds(600))
            }
        }.value
    }

    private static func request(
        leaseId: String,
        requestId: String,
        control: Bool,
        offer: SesoriRTCDescription,
        candidates: [SesoriICECandidate]
    ) -> SesoriStreamStartRequest {
        SesoriStreamStartRequest(
            requestId: requestId,
            leaseId: leaseId,
            bridgeId: "bridge-native-test",
            sessionId: "session-native-test",
            deviceKey: deviceKey,
            claimRevision: 1,
            expiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 300_000,
            control: control,
            offer: offer,
            iceCandidates: candidates,
            turn: nil
        )
    }

    private static func startedValue(
        _ result: SesoriRemoteStreamStartResult,
        label: String
    ) throws -> (answer: SesoriRTCDescription, candidates: [SesoriICECandidate]) {
        switch result {
        case let .started(answer, candidates):
            return (answer, candidates)
        case let .failed(reason):
            throw TestFailure("\(label) failed with \(reason.rawValue)")
        }
    }

    private static func expectFailure(
        _ result: SesoriRemoteStreamStartResult,
        equals expected: SesoriStreamStartFailureReason,
        _ message: String
    ) throws {
        guard case let .failed(actual) = result, actual == expected else {
            throw TestFailure(message)
        }
    }

    private static func validate(
        answer: SesoriRTCDescription,
        candidates: [SesoriICECandidate]
    ) throws {
        try expect(answer.type == .answer, "service must return an answer")
        try expect(answer.isValid, "service answer must be structurally valid")
        let normalizedSDP = answer.sdp.replacingOccurrences(of: "\r\n", with: "\n")
        let videoSections = normalizedSDP.split(separator: "\n").filter { $0.hasPrefix("m=video ") }
        try expect(videoSections.count == 1, "service answer must negotiate exactly one video section")
        try expect(
            normalizedSDP.contains("a=sendonly\n") || normalizedSDP.contains("a=sendrecv\n"),
            "service answer must negotiate a sending video direction"
        )
        try expect(
            strictSHA256Fingerprint(in: answer.sdp) == answer.fingerprint,
            "service answer fingerprint must exactly match its SDP"
        )
        try expect(candidates.count <= 64, "service must return at most 64 ICE candidates")
        try expect(!candidates.isEmpty, "service must return explicit ICE candidates")
        try expect(candidates.allSatisfy(\.isValid), "service ICE candidates must be valid")
    }

    @MainActor
    private static func bounded<Value: Sendable>(
        _ label: String,
        seconds: Int,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TestFailure("timed out waiting for \(label)")
            }
            guard let value = try await group.next() else {
                throw TestFailure("\(label) completed without a result")
            }
            group.cancelAll()
            return value
        }
    }

    @MainActor
    fileprivate static func waitUntil(
        _ label: String,
        seconds: TimeInterval,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                throw TestFailure("timed out waiting for \(label)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    fileprivate static func strictSHA256Fingerprint(in sdp: String) -> String? {
        let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else { return nil }
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("a=fingerprint:") }
        guard lines.count == 1 else { return nil }

        let fingerprint = String(lines[0].dropFirst("a=fingerprint:".count))
        let prefix = "sha-256 "
        guard fingerprint.hasPrefix(prefix) else { return nil }
        let octets = fingerprint.dropFirst(prefix.count).split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard octets.count == 32,
              octets.allSatisfy({ octet in
                  octet.utf8.count == 2 && octet.utf8.allSatisfy { byte in
                      (48...57).contains(byte) || (65...70).contains(byte)
                          || (97...102).contains(byte)
                  }
              }) else {
            return nil
        }
        return fingerprint
    }

    fileprivate static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message) }
    }
}

@MainActor
private final class LocalOfferer {
    let offer: SesoriRTCDescription
    let candidates: [SesoriICECandidate]

    private let peerConnection: RTCPeerConnection
    private let delegate: LocalOffererDelegate
    private var attachedRenderer: (any RTCVideoRenderer)?
    private var renderedTrack: RTCVideoTrack?
    private var isClosed = false

    private init(
        peerConnection: RTCPeerConnection,
        delegate: LocalOffererDelegate,
        offer: SesoriRTCDescription,
        candidates: [SesoriICECandidate]
    ) {
        self.peerConnection = peerConnection
        self.delegate = delegate
        self.offer = offer
        self.candidates = candidates
    }

    static func create(factory: RTCPeerConnectionFactory) async throws -> LocalOfferer {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.iceTransportPolicy = .all
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.iceServers = []

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let delegate = LocalOffererDelegate()
        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw TestFailure("failed to create local M151 peer connection")
        }
        do {
            let transceiverInit = RTCRtpTransceiverInit()
            transceiverInit.direction = .recvOnly
            transceiverInit.streamIds = []
            guard peerConnection.addTransceiver(of: .video, init: transceiverInit) != nil else {
                throw TestFailure("failed to add the video receive transceiver")
            }

            let createdOffer = try await peerConnection.createOffer(
                constraints: constraints,
                label: "offer creation"
            )
            try AndroidWebRTCStreamTests.expect(
                createdOffer.type == .offer,
                "M151 must create an offer"
            )
            try await peerConnection.setLocal(
                createdOffer,
                label: "offer local description"
            )
            try await AndroidWebRTCStreamTests.waitUntil(
                "non-trickle offer ICE gathering",
                seconds: 5
            ) {
                peerConnection.iceGatheringState == .complete
            }

            guard let localDescription = peerConnection.localDescription,
                  localDescription.type == .offer,
                  let fingerprint = AndroidWebRTCStreamTests.strictSHA256Fingerprint(
                      in: localDescription.sdp
                  ) else {
                throw TestFailure("gathered offer lacks one exact SHA-256 fingerprint")
            }
            let description = SesoriRTCDescription(
                type: .offer,
                sdp: localDescription.sdp,
                fingerprint: fingerprint
            )
            try AndroidWebRTCStreamTests.expect(
                description.isValid,
                "gathered offer must be structurally valid"
            )

            let candidates = mergedCandidates(
                delegate.candidates,
                candidatesFromSDP(localDescription.sdp)
            )
            try AndroidWebRTCStreamTests.expect(
                !candidates.isEmpty,
                "gathered offer must include explicit ICE candidates"
            )
            try AndroidWebRTCStreamTests.expect(
                candidates.count <= 64 && candidates.allSatisfy(\.isValid),
                "gathered offer ICE candidates must satisfy protocol limits"
            )
            return LocalOfferer(
                peerConnection: peerConnection,
                delegate: delegate,
                offer: description,
                candidates: candidates
            )
        } catch {
            peerConnection.delegate = nil
            peerConnection.close()
            throw error
        }
    }

    func apply(
        answer: SesoriRTCDescription,
        candidates: [SesoriICECandidate]
    ) async throws {
        try await peerConnection.setRemote(
            RTCSessionDescription(type: .answer, sdp: answer.sdp),
            label: "answer remote description"
        )
        for candidate in candidates {
            try await peerConnection.addRemoteCandidate(
                RTCIceCandidate(
                    sdp: candidate.candidate,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    sdpMid: candidate.sdpMid
                ),
                label: "answer ICE candidate"
            )
        }
        try AndroidWebRTCStreamTests.expect(
            peerConnection.signalingState == .stable,
            "offerer signaling must be stable after applying the answer"
        )
    }

    func waitForICEConnection() async throws {
        try await AndroidWebRTCStreamTests.waitUntil("local ICE connection", seconds: 8) {
            delegate.reachedConnectedICE
                || peerConnection.iceConnectionState == .connected
                || peerConnection.iceConnectionState == .completed
        }
    }

    func attach(renderer: any RTCVideoRenderer) throws {
        guard attachedRenderer == nil,
              let track = peerConnection.receivers
                  .compactMap({ $0.track as? RTCVideoTrack })
                  .first else {
            throw TestFailure("offerer has no available remote video track")
        }
        track.add(renderer)
        renderedTrack = track
        attachedRenderer = renderer
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let attachedRenderer, let renderedTrack {
            renderedTrack.remove(attachedRenderer)
        }
        attachedRenderer = nil
        renderedTrack = nil
        peerConnection.delegate = nil
        peerConnection.close()
    }

    private static func candidatesFromSDP(_ sdp: String) -> [SesoriICECandidate] {
        let lines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var candidates: [SesoriICECandidate] = []
        var mLineIndex: Int32 = -1
        var mid: String?
        var sectionCandidates: [String] = []

        func appendSection() {
            guard let mid, mLineIndex >= 0 else { return }
            candidates.append(contentsOf: sectionCandidates.map {
                SesoriICECandidate(candidate: $0, sdpMid: mid, sdpMLineIndex: mLineIndex)
            })
        }

        for line in lines {
            if line.hasPrefix("m=") {
                appendSection()
                mLineIndex += 1
                mid = nil
                sectionCandidates.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("a=mid:") {
                mid = String(line.dropFirst("a=mid:".count))
            } else if line.hasPrefix("a=candidate:") {
                sectionCandidates.append(String(line.dropFirst("a=".count)))
            }
        }
        appendSection()
        return candidates
    }

    private static func mergedCandidates(
        _ first: [SesoriICECandidate],
        _ second: [SesoriICECandidate]
    ) -> [SesoriICECandidate] {
        var keys: Set<String> = []
        return (first + second).filter { candidate in
            keys.insert(
                "\(candidate.sdpMLineIndex)\u{0}\(candidate.sdpMid)\u{0}\(candidate.candidate)"
            ).inserted
        }
    }
}

private struct PixelPlaneMetadata: Sendable {
    let index: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

private struct PixelBufferMetadata: Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let planes: [PixelPlaneMetadata]

    init(_ pixelBuffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        planes = (0..<CVPixelBufferGetPlaneCount(pixelBuffer)).map { index in
            PixelPlaneMetadata(
                index: index,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, index),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, index),
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
            )
        }
    }
}

private struct LiveSmokeSummary: Sendable {
    let remoteFrameCount: Int
    let remoteWidth: Int
    let remoteHeight: Int
    let local: PixelBufferMetadata
}

private struct VideoRendererSnapshot: Sendable {
    let frameCount: Int
    let width: Int
    let height: Int
}

private final class CountingVideoRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0
    private var width = 0
    private var height = 0

    var snapshot: VideoRendererSnapshot {
        lock.withLock {
            VideoRendererSnapshot(frameCount: frameCount, width: width, height: height)
        }
    }

    nonisolated func setSize(_ size: CGSize) {
        lock.withLock {
            width = Int(size.width)
            height = Int(size.height)
        }
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.withLock {
            frameCount += 1
            width = Int(frame.width)
            height = Int(frame.height)
        }
    }
}

private final class LocalOffererDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var generatedCandidates: [SesoriICECandidate] = []
    private var connectedICE = false

    var candidates: [SesoriICECandidate] {
        lock.withLock { generatedCandidates }
    }

    var reachedConnectedICE: Bool {
        lock.withLock { connectedICE }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        guard newState == .connected || newState == .completed else { return }
        lock.withLock { connectedICE = true }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        guard let mid = candidate.sdpMid else { return }
        lock.withLock {
            generatedCandidates.append(
                SesoriICECandidate(
                    candidate: candidate.sdp,
                    sdpMid: mid,
                    sdpMLineIndex: candidate.sdpMLineIndex
                )
            )
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        dataChannel.close()
    }
}

@MainActor
private final class ClosedStreamRecorder {
    private var recorded: [(leaseId: String, reason: SesoriStreamClosedReason)] = []

    func record(leaseId: String, reason: SesoriStreamClosedReason) {
        recorded.append((leaseId, reason))
    }

    func count(for leaseId: String) -> Int {
        recorded.count { $0.leaseId == leaseId }
    }

    func events(for leaseId: String) -> [SesoriStreamClosedReason] {
        recorded.compactMap { $0.leaseId == leaseId ? $0.reason : nil }
    }
}

private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class CallbackGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func arm(label: String) {
        let task = Task.detached { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: AndroidWebRTCStreamTests.callbackTimeoutNanoseconds
                )
            } catch {
                return
            }
            self?.resolve(.failure(TestFailure("timed out waiting for \(label)")))
        }
        lock.withLock {
            if continuation == nil {
                task.cancel()
            } else {
                timeoutTask = task
            }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        let resolved: (CheckedContinuation<Value, Error>, Task<Void, Never>?)? = lock.withLock {
            guard let continuation else { return nil }
            self.continuation = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            return (continuation, timeoutTask)
        }
        guard let resolved else { return }
        resolved.1?.cancel()
        resolved.0.resume(with: result)
    }
}

private extension RTCPeerConnection {
    @MainActor
    func createOffer(
        constraints: RTCMediaConstraints,
        label: String
    ) async throws -> RTCSessionDescription {
        let box: UnsafeSendableBox<RTCSessionDescription> = try await withCheckedThrowingContinuation {
            continuation in
            let gate = CallbackGate(continuation)
            gate.arm(label: label)
            offer(for: constraints) { description, error in
                if let description {
                    gate.resolve(.success(UnsafeSendableBox(description)))
                } else {
                    gate.resolve(.failure(TestFailure.callback(label, error: error)))
                }
            }
        }
        return box.value
    }

    @MainActor
    func setLocal(_ description: RTCSessionDescription, label: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CallbackGate<Void>(continuation)
            gate.arm(label: label)
            setLocalDescription(description) { error in
                if let error {
                    gate.resolve(.failure(TestFailure.callback(label, error: error)))
                } else {
                    gate.resolve(.success(()))
                }
            }
        }
    }

    @MainActor
    func setRemote(_ description: RTCSessionDescription, label: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CallbackGate<Void>(continuation)
            gate.arm(label: label)
            setRemoteDescription(description) { error in
                if let error {
                    gate.resolve(.failure(TestFailure.callback(label, error: error)))
                } else {
                    gate.resolve(.success(()))
                }
            }
        }
    }

    @MainActor
    func addRemoteCandidate(_ candidate: RTCIceCandidate, label: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CallbackGate<Void>(continuation)
            gate.arm(label: label)
            add(candidate) { error in
                if let error {
                    gate.resolve(.failure(TestFailure.callback(label, error: error)))
                } else {
                    gate.resolve(.success(()))
                }
            }
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    static func callback(_ label: String, error: Error?) -> TestFailure {
        TestFailure(error == nil ? "\(label) returned no value" : "\(label) callback failed")
    }
}
