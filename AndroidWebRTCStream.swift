import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox
@preconcurrency import WebRTC

@MainActor
final class AndroidWebRTCService: SesoriRemoteStreamHandling {
    private let runtime = AndroidWebRTCRuntime()
    private var endpoints: [String: AndroidEmulatorStreamEndpoint] = [:]
    private var peersByDevice: [String: AndroidWebRTCPeer] = [:]
    private var peersByLease: [String: AndroidWebRTCPeer] = [:]
    private var streamClosedHandler: (@MainActor (String, SesoriStreamClosedReason) -> Void)?

    init() {}

    var capabilities: CanvasCapabilities {
        .androidRemoteVideo
    }

    func register(endpoint: AndroidEmulatorStreamEndpoint, for deviceKey: String) {
        guard deviceKey.hasPrefix("android-"),
              String(deviceKey.dropFirst("android-".count)) == endpoint.serial else {
            return
        }
        if let current = endpoints[deviceKey], current !== endpoint {
            unregisterEndpoint(for: deviceKey)
        }
        endpoints[deviceKey] = endpoint
    }

    func unregisterEndpoint(for deviceKey: String) {
        endpoints.removeValue(forKey: deviceKey)
        guard let peer = peersByDevice[deviceKey] else { return }
        peer.stop(reporting: .stopped)
        remove(peer)
    }

    func startStream(_ request: SesoriStreamStartRequest) async -> SesoriRemoteStreamStartResult {
        guard request.deviceKey.hasPrefix("android-") else {
            return .failed(.unsupported)
        }
        guard !request.control else {
            return .failed(.unsupported)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard request.isValid,
              request.expiresAt > now,
              (request.turn?.expiresAt ?? Int64.max) > now else {
            return .failed(.invalidOffer)
        }
        guard runtime.factory != nil,
              let endpoint = endpoints[request.deviceKey],
              endpoint.serial == String(request.deviceKey.dropFirst("android-".count)) else {
            return .failed(.peerSetupFailed)
        }
        guard peersByDevice[request.deviceKey] == nil,
              peersByLease[request.leaseId] == nil else {
            return .failed(.peerSetupFailed)
        }

        let peer = AndroidWebRTCPeer(
            request: request,
            endpoint: endpoint,
            runtime: runtime,
            onClosed: { [weak self] peer, reason in
                guard let self,
                      self.peersByLease[peer.leaseId] === peer else { return }
                self.remove(peer)
                self.streamClosedHandler?(peer.leaseId, reason)
            }
        )
        peersByDevice[request.deviceKey] = peer
        peersByLease[request.leaseId] = peer

        let result = await withTaskCancellationHandler {
            await peer.start()
        } onCancel: {
            Task { @MainActor [weak peer] in
                peer?.stop(reporting: nil)
            }
        }
        if case .failed = result, peersByLease[request.leaseId] === peer {
            remove(peer)
        }
        return result
    }

    func revokeStream(leaseId: String, reason: SesoriStreamRevokeReason) {
        guard let peer = peersByLease[leaseId] else { return }
        remove(peer)
        peer.stop(reporting: nil)
    }

    func closeAllStreams() {
        let peers = Array(peersByLease.values)
        peersByDevice.removeAll()
        peersByLease.removeAll()
        for peer in peers {
            peer.stop(reporting: .stopped)
        }
    }

    func setStreamClosedHandler(
        _ handler: @escaping @MainActor (String, SesoriStreamClosedReason) -> Void
    ) {
        streamClosedHandler = handler
    }

    private func remove(_ peer: AndroidWebRTCPeer) {
        if peersByDevice[peer.deviceKey] === peer {
            peersByDevice.removeValue(forKey: peer.deviceKey)
        }
        if peersByLease[peer.leaseId] === peer {
            peersByLease.removeValue(forKey: peer.leaseId)
        }
    }

    isolated deinit {
        for peer in peersByLease.values {
            peer.stop(reporting: nil)
        }
    }
}

private final class AndroidWebRTCRuntime: @unchecked Sendable {
    private let initializedSSL: Bool
    private(set) var factory: RTCPeerConnectionFactory?

    init() {
        initializedSSL = RTCInitializeSSL()
        if initializedSSL {
            factory = RTCPeerConnectionFactory()
        }
    }

    deinit {
        factory = nil
        if initializedSSL {
            _ = RTCCleanupSSL()
        }
    }
}

enum AndroidWebRTCPeerConfiguration {
    static func make(
        turn: SesoriTURNConfiguration?,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> RTCConfiguration? {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require

        if let turn {
            guard turn.isValid,
                  let canonicalURLs = turn.canonicalURLs,
                  turn.expiresAt > now else {
                return nil
            }
            configuration.iceTransportPolicy = .relay
            configuration.iceServers = [
                RTCIceServer(
                    urlStrings: canonicalURLs,
                    username: turn.username,
                    credential: turn.credential
                )
            ]
        } else {
            configuration.iceTransportPolicy = .all
            configuration.iceServers = []
        }
        return configuration
    }
}

@MainActor
private final class AndroidWebRTCPeer: NSObject, RTCPeerConnectionDelegate {
    let deviceKey: String
    let leaseId: String

    private let request: SesoriStreamStartRequest
    private let endpoint: AndroidEmulatorStreamEndpoint
    private let runtime: AndroidWebRTCRuntime
    private let onClosed: @MainActor (AndroidWebRTCPeer, SesoriStreamClosedReason) -> Void
    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    private var peerConnection: RTCPeerConnection?
    private var decoder: AndroidWebRTCFrameDecoder?
    private var timeoutTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var completion: ((SesoriRemoteStreamStartResult) -> Void)?
    private var localCandidates: [SesoriICECandidate] = []
    private var candidateKeys: Set<String> = []
    private var endpointAttached = false
    private var setupSucceeded = false
    private var stopped = false

    init(
        request: SesoriStreamStartRequest,
        endpoint: AndroidEmulatorStreamEndpoint,
        runtime: AndroidWebRTCRuntime,
        onClosed: @escaping @MainActor (AndroidWebRTCPeer, SesoriStreamClosedReason) -> Void
    ) {
        deviceKey = request.deviceKey
        leaseId = request.leaseId
        self.request = request
        self.endpoint = endpoint
        self.runtime = runtime
        self.onClosed = onClosed
        super.init()
    }

    isolated deinit {
        stop(reporting: nil)
    }

    func start() async -> SesoriRemoteStreamStartResult {
        await withCheckedContinuation { continuation in
            guard completion == nil, !stopped else {
                continuation.resume(returning: .failed(.peerSetupFailed))
                return
            }
            completion = { result in continuation.resume(returning: result) }
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                self?.failSetup(.peerSetupFailed)
            }
            beginSetup()
        }
    }

    func stop(reporting reason: SesoriStreamClosedReason?) {
        guard !stopped else { return }
        let shouldReport = setupSucceeded && reason != nil
        stopped = true
        timeoutTask?.cancel()
        timeoutTask = nil
        disconnectTask?.cancel()
        disconnectTask = nil

        if let completion {
            self.completion = nil
            completion(.failed(.peerSetupFailed))
        }

        decoder?.shutdown()
        if endpointAttached, let decoder {
            endpointAttached = false
            endpoint.detach(decoder)
        }
        decoder = nil

        if let peerConnection {
            self.peerConnection = nil
            peerConnection.delegate = nil
            peerConnection.close()
        }

        if shouldReport, let reason {
            onClosed(self, reason)
        }
    }

    private func beginSetup() {
        guard request.offer.type == .offer,
              request.offer.isValid,
              let factory = runtime.factory else {
            failSetup(.invalidOffer)
            return
        }

        guard let configuration = AndroidWebRTCPeerConfiguration.make(turn: request.turn) else {
            failSetup(.peerSetupFailed)
            return
        }

        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            failSetup(.peerSetupFailed)
            return
        }
        self.peerConnection = peerConnection

        let source = factory.videoSource(forScreenCast: true)
        // Level 3.1 H.264 peers allow 3,600 macroblocks. Scale only the remote
        // branch so the existing 1,600-pixel local scrcpy renderer is unchanged.
        source.adaptOutputFormat(toWidth: 640, height: 1440, fps: 30)
        let capturer = RTCVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "device-canvas-video")
        guard peerConnection.add(track, streamIds: ["device-canvas-stream"]) != nil else {
            failSetup(.peerSetupFailed)
            return
        }

        let decoder = AndroidWebRTCFrameDecoder(
            videoSource: source,
            videoCapturer: capturer,
            requestKeyframe: { [weak endpoint] in
                Task { @MainActor in endpoint?.requestKeyframe() }
            }
        )
        self.decoder = decoder
        guard endpoint.attach(decoder) else {
            failSetup(.peerSetupFailed)
            return
        }
        endpointAttached = true

        let remote = RTCSessionDescription(type: .offer, sdp: request.offer.sdp)
        peerConnection.setRemoteDescription(remote) { [weak self] error in
            let errorBox = AndroidWebRTCUnsafeBox(error)
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if errorBox.value != nil {
                    self.failSetup(.invalidOffer)
                } else {
                    self.addRemoteCandidate(at: 0)
                }
            }
        }
    }

    private func addRemoteCandidate(at index: Int) {
        guard let peerConnection, index < request.iceCandidates.count else {
            createAnswer()
            return
        }
        let candidate = request.iceCandidates[index]
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        peerConnection.add(rtcCandidate) { [weak self] error in
            let errorBox = AndroidWebRTCUnsafeBox(error)
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if errorBox.value != nil {
                    self.failSetup(.invalidOffer)
                } else {
                    self.addRemoteCandidate(at: index + 1)
                }
            }
        }
    }

    private func createAnswer() {
        guard let peerConnection else {
            failSetup(.peerSetupFailed)
            return
        }
        peerConnection.answer(for: constraints) { [weak self] answer, error in
            let box = AndroidWebRTCUnsafeBox((answer, error))
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                guard box.value.1 == nil, let answer = box.value.0 else {
                    self.failSetup(.peerSetupFailed)
                    return
                }
                self.setLocalDescription(answer)
            }
        }
    }

    private func setLocalDescription(_ answer: RTCSessionDescription) {
        guard let peerConnection else {
            failSetup(.peerSetupFailed)
            return
        }
        peerConnection.setLocalDescription(answer) { [weak self] error in
            let errorBox = AndroidWebRTCUnsafeBox(error)
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if errorBox.value != nil {
                    self.failSetup(.peerSetupFailed)
                } else if self.peerConnection?.iceGatheringState == .complete {
                    self.completeGathering()
                }
            }
        }
    }

    private func completeGathering() {
        guard !setupSucceeded,
              completion != nil,
              let sdp = peerConnection?.localDescription?.sdp,
              let fingerprint = Self.strictSHA256Fingerprint(in: sdp) else {
            failSetup(.peerSetupFailed)
            return
        }
        mergeCandidates(from: sdp)
        let description = SesoriRTCDescription(type: .answer, sdp: sdp, fingerprint: fingerprint)
        guard description.isValid,
              localCandidates.count <= 64,
              localCandidates.allSatisfy(\.isValid) else {
            failSetup(.peerSetupFailed)
            return
        }

        setupSucceeded = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let completion = self.completion
        self.completion = nil
        completion?(.started(answer: description, iceCandidates: localCandidates))
    }

    private func mergeCandidates(from sdp: String) {
        let lines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var sections: [[Substring]] = []
        for line in lines where line.hasPrefix("m=") || !sections.isEmpty {
            if line.hasPrefix("m=") {
                sections.append([])
            }
            sections[sections.count - 1].append(line)
        }

        for (index, section) in sections.enumerated() where index <= Int(Int32.max) {
            guard let midLine = section.first(where: { $0.hasPrefix("a=mid:") }) else { continue }
            let mid = String(midLine.dropFirst("a=mid:".count))
            for line in section where line.hasPrefix("a=candidate:") {
                recordLocalCandidate(
                    SesoriICECandidate(
                        candidate: String(line.dropFirst("a=".count)),
                        sdpMid: mid,
                        sdpMLineIndex: Int32(index)
                    )
                )
            }
        }
    }

    private func recordLocalCandidate(_ candidate: SesoriICECandidate) {
        let key = "\(candidate.sdpMLineIndex)\u{0}\(candidate.sdpMid)\u{0}\(candidate.candidate)"
        guard candidateKeys.insert(key).inserted else { return }
        localCandidates.append(candidate)
    }

    private func failSetup(_ reason: SesoriStreamStartFailureReason) {
        guard !stopped else { return }
        let completion = self.completion
        self.completion = nil
        stop(reporting: nil)
        completion?(.failed(reason))
    }

    private static func strictSHA256Fingerprint(in sdp: String) -> String? {
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
                      (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
                  }
              }) else {
            return nil
        }
        return fingerprint
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
        guard newState == .failed || newState == .closed else { return }
        Task { @MainActor [weak self, weak peerConnection] in
            guard let self,
                  let peerConnection,
                  self.peerConnection === peerConnection,
                  !self.stopped else { return }
            if self.setupSucceeded {
                self.stop(reporting: .failed)
            } else {
                self.failSetup(.peerSetupFailed)
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.stopped else { return }
            self.completeGathering()
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        let box = AndroidWebRTCUnsafeBox(candidate)
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.stopped else { return }
            let candidate = box.value
            guard let sdpMid = candidate.sdpMid else { return }
            self.recordLocalCandidate(
                SesoriICECandidate(
                    candidate: candidate.sdp,
                    sdpMid: sdpMid,
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

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        Task { @MainActor [weak self, weak peerConnection] in
            guard let self,
                  let peerConnection,
                  self.peerConnection === peerConnection,
                  !self.stopped else { return }
            switch newState {
            case .connected:
                self.disconnectTask?.cancel()
                self.disconnectTask = nil
            case .disconnected:
                guard self.disconnectTask == nil else { return }
                self.disconnectTask = Task { [weak self, weak peerConnection] in
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.disconnectTask = nil
                    guard let peerConnection,
                          self.peerConnection === peerConnection,
                          peerConnection.connectionState == .disconnected,
                          !self.stopped else {
                        return
                    }
                    if self.setupSucceeded {
                        self.stop(reporting: .failed)
                    } else {
                        self.failSetup(.peerSetupFailed)
                    }
                }
            case .failed, .closed:
                if self.setupSucceeded {
                    self.stop(reporting: .failed)
                } else {
                    self.failSetup(.peerSetupFailed)
                }
            default:
                break
            }
        }
    }
}

private final class AndroidWebRTCUnsafeBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private struct AndroidWebRTCPendingFrame: @unchecked Sendable {
    let frame: AndroidEmulatorCompressedFrame
    let context: AndroidEmulatorStreamContext
}

private final class AndroidWebRTCDecodeTicket: @unchecked Sendable {
    weak var owner: AndroidWebRTCFrameDecoder?
    let pending: AndroidWebRTCPendingFrame
    let decoderGeneration: Int

    init(
        owner: AndroidWebRTCFrameDecoder,
        pending: AndroidWebRTCPendingFrame,
        decoderGeneration: Int
    ) {
        self.owner = owner
        self.pending = pending
        self.decoderGeneration = decoderGeneration
    }
}

private final class AndroidWebRTCFrameDecoder: @unchecked Sendable, AndroidEmulatorFrameSink {
    private let videoSource: RTCVideoSource
    private let videoCapturer: RTCVideoCapturer
    private let requestKeyframe: @Sendable () -> Void
    private let decoderQueue = DispatchQueue(
        label: "device-canvas.android-webrtc.decoder",
        qos: .userInitiated
    )
    private let acceptingFrames = Atomic<Bool>(true)
    private let activeDecoderGeneration = Atomic<Int>(0)
    private let discontinuityPending = Atomic<Bool>(false)
    private var handoffMutex = pthread_mutex_t()
    private var retainedFrames: [AndroidWebRTCPendingFrame] = []
    private var drainScheduled = false

    // Decoder-queue confined.
    private var decompressionSession: VTDecompressionSession?
    private var decoderFormat: CMVideoFormatDescription?
    private var currentContext: AndroidEmulatorStreamContext?
    private var waitingForKeyframe = true
    private var keyframeRequested = false
    private var decoderGeneration = 0
    private var lastCapturedSourceTimeNanoseconds: UInt64 = 0
    private var inFlightDecodeCount = 0

    private static let maximumRetainedFrames = 8
    private static let maximumInFlightDecodes = 4

    init(
        videoSource: RTCVideoSource,
        videoCapturer: RTCVideoCapturer,
        requestKeyframe: @escaping @Sendable () -> Void
    ) {
        self.videoSource = videoSource
        self.videoCapturer = videoCapturer
        self.requestKeyframe = requestKeyframe
        pthread_mutex_init(&handoffMutex, nil)
    }

    deinit {
        pthread_mutex_destroy(&handoffMutex)
    }

    // Runs synchronously on the source queue and never waits for decoder work.
    func offer(
        _ frame: AndroidEmulatorCompressedFrame,
        context: AndroidEmulatorStreamContext
    ) {
        guard acceptingFrames.load(ordering: .acquiring) else {
            return
        }
        guard pthread_mutex_trylock(&handoffMutex) == 0 else {
            markDiscontinuity()
            return
        }
        guard acceptingFrames.load(ordering: .relaxed) else {
            pthread_mutex_unlock(&handoffMutex)
            return
        }

        var shouldRequestKeyframe = false
        if retainedFrames.count == Self.maximumRetainedFrames {
            retainedFrames.removeAll(keepingCapacity: true)
            shouldRequestKeyframe = !discontinuityPending.exchange(
                true,
                ordering: .acquiringAndReleasing
            )
        }
        retainedFrames.append(AndroidWebRTCPendingFrame(frame: frame, context: context))
        if !drainScheduled {
            drainScheduled = true
            decoderQueue.async { [weak self] in self?.drainFrames() }
        }
        pthread_mutex_unlock(&handoffMutex)
        if shouldRequestKeyframe { requestKeyframe() }
    }

    func sessionDidEnd(_ context: AndroidEmulatorStreamContext) {
        guard acceptingFrames.load(ordering: .acquiring) else { return }
        decoderQueue.async { [weak self] in
            guard let self,
                  self.acceptingFrames.load(ordering: .acquiring),
                  self.currentContext == context else {
                return
            }
            self.resetDecoder(nextContext: nil)
        }
    }

    func shutdown() {
        guard acceptingFrames.exchange(false, ordering: .acquiringAndReleasing) else { return }
        pthread_mutex_lock(&handoffMutex)
        retainedFrames.removeAll()
        pthread_mutex_unlock(&handoffMutex)

        decoderQueue.async { [self] in
            pthread_mutex_lock(&handoffMutex)
            retainedFrames.removeAll()
            drainScheduled = false
            pthread_mutex_unlock(&handoffMutex)
            resetDecoder(nextContext: nil)
        }
    }

    private func drainFrames() {
        while acceptingFrames.load(ordering: .acquiring),
              inFlightDecodeCount < Self.maximumInFlightDecodes {
            pthread_mutex_lock(&handoffMutex)
            guard !retainedFrames.isEmpty else {
                drainScheduled = false
                pthread_mutex_unlock(&handoffMutex)
                return
            }
            let pending = retainedFrames.removeFirst()
            pthread_mutex_unlock(&handoffMutex)
            if discontinuityPending.exchange(false, ordering: .acquiringAndReleasing) {
                resetDecoder(nextContext: pending.context)
            }
            decode(pending)
        }

        if acceptingFrames.load(ordering: .acquiring),
           inFlightDecodeCount >= Self.maximumInFlightDecodes {
            return
        }

        pthread_mutex_lock(&handoffMutex)
        retainedFrames.removeAll()
        drainScheduled = false
        pthread_mutex_unlock(&handoffMutex)
    }

    private func decode(_ pending: AndroidWebRTCPendingFrame) {
        guard acceptingFrames.load(ordering: .acquiring),
              let format = CMSampleBufferGetFormatDescription(pending.frame.sampleBuffer) else {
            return
        }

        if currentContext != pending.context {
            resetDecoder(nextContext: pending.context)
        }
        if let decoderFormat,
           !CMFormatDescriptionEqual(decoderFormat, otherFormatDescription: format) {
            resetDecoder(nextContext: pending.context)
        }
        if decoderFormat == nil {
            waitingForKeyframe = true
        }
        guard !waitingForKeyframe || pending.frame.isKeyframe else {
            if !keyframeRequested {
                keyframeRequested = true
                requestKeyframe()
            }
            return
        }
        keyframeRequested = false

        if decompressionSession == nil {
            guard createDecoder(format: format) else {
                requestKeyframe()
                return
            }
            waitingForKeyframe = false
        }
        guard let decompressionSession else { return }

        let ticket = AndroidWebRTCDecodeTicket(
            owner: self,
            pending: pending,
            decoderGeneration: decoderGeneration
        )
        let ticketPointer = Unmanaged.passRetained(ticket).toOpaque()
        var infoFlags = VTDecodeInfoFlags()
        inFlightDecodeCount += 1
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: pending.frame.sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: ticketPointer,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            inFlightDecodeCount -= 1
            Unmanaged<AndroidWebRTCDecodeTicket>.fromOpaque(ticketPointer).release()
            resetDecoder(nextContext: pending.context)
            markDiscontinuity()
        }
    }

    private func markDiscontinuity() {
        if !discontinuityPending.exchange(true, ordering: .acquiringAndReleasing) {
            requestKeyframe()
        }
    }

    private func createDecoder(format: CMVideoFormatDescription) -> Bool {
        decoderGeneration += 1
        activeDecoderGeneration.store(decoderGeneration, ordering: .releasing)
        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decompressionCallback,
            decompressionOutputRefCon: nil
        )
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            waitingForKeyframe = true
            return false
        }

        decompressionSession = session
        decoderFormat = format
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return true
    }

    private func resetDecoder(nextContext: AndroidEmulatorStreamContext?) {
        decoderGeneration += 1
        activeDecoderGeneration.store(decoderGeneration, ordering: .releasing)
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        decoderFormat = nil
        currentContext = nextContext
        waitingForKeyframe = true
        keyframeRequested = false
    }

    private static let decompressionCallback: VTDecompressionOutputCallback = {
        _, sourceFrameRefCon, status, infoFlags, imageBuffer, _, _ in
        guard let sourceFrameRefCon else { return }
        let ticket = Unmanaged<AndroidWebRTCDecodeTicket>
            .fromOpaque(sourceFrameRefCon)
            .takeRetainedValue()
        guard let owner = ticket.owner else { return }
        let output = AndroidWebRTCUnsafeBox((status, infoFlags, imageBuffer))
        owner.decoderQueue.async { [weak owner] in
            owner?.decoded(
                ticket: ticket,
                status: output.value.0,
                infoFlags: output.value.1,
                imageBuffer: output.value.2
            )
        }
    }

    private func decoded(
        ticket: AndroidWebRTCDecodeTicket,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?
    ) {
        inFlightDecodeCount = max(0, inFlightDecodeCount - 1)
        defer { drainFrames() }

        guard acceptingFrames.load(ordering: .acquiring),
              ticket.decoderGeneration == activeDecoderGeneration.load(ordering: .acquiring),
              status == noErr,
              let imageBuffer,
              ticket.pending.frame.sourceTimeNanoseconds <= UInt64(Int64.max) else {
            if status != noErr || infoFlags.contains(.frameDropped) {
                resetDecoder(nextContext: ticket.pending.context)
                markDiscontinuity()
            }
            return
        }
        guard !infoFlags.contains(.frameDropped) else {
            resetDecoder(nextContext: ticket.pending.context)
            markDiscontinuity()
            return
        }

        let sourceTime = ticket.pending.frame.sourceTimeNanoseconds
        guard acceptingFrames.load(ordering: .acquiring),
              ticket.decoderGeneration == activeDecoderGeneration.load(ordering: .acquiring),
              sourceTime > lastCapturedSourceTimeNanoseconds else {
            return
        }
        lastCapturedSourceTimeNanoseconds = sourceTime

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: imageBuffer)
        let rtcFrame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: Int64(sourceTime)
        )
        videoSource.capturer(videoCapturer, didCapture: rtcFrame)
    }
}
