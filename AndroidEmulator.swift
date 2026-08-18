import AppKit
import AVFoundation
import Darwin
import Foundation
import SwiftUI

struct AndroidEmulatorRecord: Sendable {
    let serial: String
    let name: String
    let runtime: String
}

enum AndroidEmulatorError: LocalizedError {
    case commandFailed(Int32)
    case commandTimedOut
    case scrcpyNotFound

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status):
            "adb exited with status \(status)"
        case .commandTimedOut:
            "adb timed out"
        case .scrcpyNotFound:
            "scrcpy 4.1 is required"
        }
    }
}

enum AndroidSDK {
    static let adbURL: URL? = {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let sdkRoot = environment["ANDROID_SDK_ROOT"] {
            candidates.append("\(sdkRoot)/platform-tools/adb")
        }
        if let androidHome = environment["ANDROID_HOME"] {
            candidates.append("\(androidHome)/platform-tools/adb")
        }
        if let home = environment["HOME"] {
            candidates.append("\(home)/Library/Android/sdk/platform-tools/adb")
        }

        return candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static func runADB(_ arguments: [String], timeout: TimeInterval = 5) throws -> Data {
        guard let adbURL else {
            return Data()
        }

        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = adbURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        try process.run()
        guard termination.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw AndroidEmulatorError.commandTimedOut
        }

        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            throw AndroidEmulatorError.commandFailed(process.terminationStatus)
        }

        return data
    }

    static func runADBText(_ arguments: [String]) throws -> String {
        String(decoding: try runADB(arguments), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ScrcpyInstallation: Sendable {
    let serverURL: URL
    let version: String

    static let current: ScrcpyInstallation? = {
        let environment = ProcessInfo.processInfo.environment
        var executables: [URL] = []
        if let configured = environment["SCRCPY"] {
            executables.append(URL(fileURLWithPath: configured))
        }
        executables.append(URL(fileURLWithPath: "/opt/homebrew/bin/scrcpy"))
        executables.append(URL(fileURLWithPath: "/usr/local/bin/scrcpy"))

        for executable in executables where FileManager.default.isExecutableFile(atPath: executable.path) {
            guard let version = scrcpyVersion(at: executable), version == "4.1" else {
                continue
            }

            let resolvedExecutable = executable.resolvingSymlinksInPath()
            let prefix = resolvedExecutable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            var serverCandidates: [URL] = []
            if let configuredServer = environment["SCRCPY_SERVER_PATH"] {
                serverCandidates.append(URL(fileURLWithPath: configuredServer))
            }
            serverCandidates.append(
                prefix.appendingPathComponent("share/scrcpy/scrcpy-server")
            )
            serverCandidates.append(
                executable
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("share/scrcpy/scrcpy-server")
            )

            if let serverURL = serverCandidates.first(where: {
                FileManager.default.isReadableFile(atPath: $0.path)
            }) {
                return ScrcpyInstallation(serverURL: serverURL, version: version)
            }
        }
        return nil
    }()

    private static func scrcpyVersion(at executable: URL) -> String? {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let firstLine = String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \Character.isNewline)
                .first else {
            return nil
        }
        let fields = firstLine.split(whereSeparator: \Character.isWhitespace)
        return fields.count >= 2 && fields[0] == "scrcpy" ? String(fields[1]) : nil
    }
}

enum AndroidEmulatorDiscovery {
    static func runningEmulators() async throws -> [AndroidEmulatorRecord] {
        guard AndroidSDK.adbURL != nil else {
            return []
        }
        guard ScrcpyInstallation.current != nil else {
            throw AndroidEmulatorError.scrcpyNotFound
        }

        return try await Task.detached(priority: .utility) {
            let output = try AndroidSDK.runADBText(["devices", "-l"])
            let serials = output
                .split(whereSeparator: \Character.isNewline)
                .compactMap { line -> String? in
                    let fields = line.split(whereSeparator: \Character.isWhitespace)
                    guard fields.count >= 2,
                          fields[0].hasPrefix("emulator-"),
                          fields[1] == "device" else {
                        return nil
                    }
                    return String(fields[0])
                }

            var emulators: [AndroidEmulatorRecord] = []
            for serial in serials {
                guard let avdName = try officialAVDName(for: serial) else {
                    continue
                }

                let version = try AndroidSDK.runADBText([
                    "-s", serial, "shell", "getprop", "ro.build.version.release"
                ])
                let runtime = version.isEmpty ? "Android" : "Android \(version)"

                emulators.append(AndroidEmulatorRecord(
                    serial: serial,
                    name: avdName.replacingOccurrences(of: "_", with: " "),
                    runtime: runtime
                ))
            }
            return emulators.sorted { ($0.name, $0.serial) < ($1.name, $1.serial) }
        }.value
    }

    private static func officialAVDName(for serial: String) throws -> String? {
        let name = try AndroidSDK.runADBText([
            "-s", serial, "shell", "getprop", "ro.boot.qemu.avd_name"
        ])
        guard !name.isEmpty, hasLocalAVDDefinition(named: name) else {
            return nil
        }

        return name
    }

    private static func hasLocalAVDDefinition(named name: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let avdDirectory: URL

        if let avdHome = environment["ANDROID_AVD_HOME"] {
            avdDirectory = URL(fileURLWithPath: avdHome, isDirectory: true)
        } else if let androidUserHome = environment["ANDROID_USER_HOME"] {
            avdDirectory = URL(fileURLWithPath: androidUserHome, isDirectory: true)
                .appendingPathComponent("avd", isDirectory: true)
        } else {
            avdDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".android/avd", isDirectory: true)
        }

        return FileManager.default.fileExists(
            atPath: avdDirectory.appendingPathComponent("\(name).ini").path
        )
    }

}

struct AndroidEmulatorView: NSViewRepresentable {
    let serial: String

    func makeNSView(context: Context) -> AndroidEmulatorScreenView {
        AndroidEmulatorScreenView(serial: serial)
    }

    func updateNSView(_ nsView: AndroidEmulatorScreenView, context: Context) {}

    static func dismantleNSView(_ nsView: AndroidEmulatorScreenView, coordinator: ()) {
        nsView.stop()
    }
}

final class AndroidEmulatorScreenView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var stream: AndroidEmulatorStream!
    private var videoSize = CGSize.zero
    private var isTouching = false

    init(serial: String) {
        super.init(frame: .zero)

        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        wantsLayer = true
        layer = displayLayer

        stream = AndroidEmulatorStream(
            serial: serial,
            renderer: displayLayer.sampleBufferRenderer,
            target: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        stream.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let position = devicePosition(for: event, clamped: false) else {
            return
        }
        isTouching = true
        stream.injectTouch(action: 0, position: position, pressure: 1)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTouching, let position = devicePosition(for: event, clamped: true) else {
            return
        }
        stream.injectTouch(action: 2, position: position, pressure: 1)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching, let position = devicePosition(for: event, clamped: true) else {
            return
        }
        isTouching = false
        stream.injectTouch(action: 1, position: position, pressure: 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stream.injectBack(action: 0)
    }

    override func rightMouseUp(with event: NSEvent) {
        stream.injectBack(action: 1)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            return
        }
        window?.makeFirstResponder(self)
        stream.injectKeycode(action: 0, keycode: 3, repeatCount: 0, metastate: 0)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            return
        }
        stream.injectKeycode(action: 1, keycode: 3, repeatCount: 0, metastate: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let position = devicePosition(for: event, clamped: false) else {
            return
        }
        stream.injectScroll(
            position: position,
            horizontal: Float(event.scrollingDeltaX),
            vertical: Float(event.scrollingDeltaY)
        )
    }

    override func keyDown(with event: NSEvent) {
        if let keycode = androidKeycode(for: event) {
            stream.injectKeycode(
                action: 0,
                keycode: keycode,
                repeatCount: event.isARepeat ? 1 : 0,
                metastate: androidMetastate(for: event)
            )
        } else if !event.isARepeat, let text = event.characters, !text.isEmpty {
            stream.injectText(text)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let keycode = androidKeycode(for: event) else {
            return
        }
        stream.injectKeycode(
            action: 1,
            keycode: keycode,
            repeatCount: 0,
            metastate: androidMetastate(for: event)
        )
    }

    func updateVideoSize(_ size: CGSize) {
        videoSize = size
    }

    func stop() {
        stream.stop(cancelTouch: isTouching)
        isTouching = false
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
    }

    @objc private func applicationWillTerminate() {
        stop()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stream.stop()
    }

    private func devicePosition(for event: NSEvent, clamped: Bool) -> ScrcpyPosition? {
        guard videoSize.width > 0, videoSize.height > 0 else {
            return nil
        }

        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let contentSize = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let contentRect = CGRect(
            x: (bounds.width - contentSize.width) / 2,
            y: (bounds.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        var point = convert(event.locationInWindow, from: nil)
        if !clamped, !contentRect.contains(point) {
            return nil
        }
        point.x = min(max(point.x, contentRect.minX), contentRect.maxX.nextDown)
        point.y = min(max(point.y, contentRect.minY), contentRect.maxY.nextDown)

        let pixelWidth = max(1, Int32(videoSize.width))
        let pixelHeight = max(1, Int32(videoSize.height))
        let x = min(
            max(0, Int32((point.x - contentRect.minX) / scale)),
            pixelWidth - 1
        )
        let y = min(
            max(0, Int32((contentRect.maxY - point.y) / scale)),
            pixelHeight - 1
        )
        return ScrcpyPosition(
            x: x,
            y: y,
            width: UInt16(pixelWidth),
            height: UInt16(pixelHeight)
        )
    }

    func resetInputState() {
        isTouching = false
    }

    private func androidKeycode(for event: NSEvent) -> UInt32? {
        let specialKeycodes: [UInt16: UInt32] = [
            36: 66, 48: 61, 51: 67, 53: 111,
            115: 122, 116: 92, 117: 112, 119: 123, 121: 93,
            123: 21, 124: 22, 125: 20, 126: 19
        ]
        if let keycode = specialKeycodes[event.keyCode] {
            return keycode
        }

        guard let character = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first else {
            return nil
        }
        switch character.value {
        case 97...122:
            return 29 + character.value - 97
        case 48...57:
            return 7 + character.value - 48
        default:
            return [
                " ": 62, ",": 55, ".": 56, "`": 68, "-": 69,
                "=": 70, "[": 71, "]": 72, "\\": 73, ";": 74,
                "'": 75, "/": 76
            ][Character(String(character))]
        }
    }

    private func androidMetastate(for event: NSEvent) -> UInt32 {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var state: UInt32 = 0
        if flags.contains(.shift) { state |= 0x1 }
        if flags.contains(.option) { state |= 0x2 }
        if flags.contains(.control) { state |= 0x1000 }
        if flags.contains(.command) { state |= 0x10000 }
        if flags.contains(.capsLock) { state |= 0x100000 }
        return state
    }
}

private struct ScrcpyPosition {
    let x: Int32
    let y: Int32
    let width: UInt16
    let height: UInt16
}

private final class AndroidEmulatorStream: @unchecked Sendable {
    private let serial: String
    private let renderer: AVSampleBufferVideoRenderer
    private weak var target: AndroidEmulatorScreenView?
    private let queue: DispatchQueue
    private let workerQueue: DispatchQueue
    private var parser = H264AnnexBParser()
    private var serverProcess: Process?
    private var videoSocket: Int32 = -1
    private var controlSocket: Int32 = -1
    private var isActive = false
    private var pendingFrames: [H264Frame] = []
    private var isWaitingForKeyframe = false
    private var isDrainScheduled = false
    private var generation = 0
    private var lastVideoSize = CGSize.zero

    init(
        serial: String,
        renderer: AVSampleBufferVideoRenderer,
        target: AndroidEmulatorScreenView
    ) {
        self.serial = serial
        self.renderer = renderer
        self.target = target
        queue = DispatchQueue(label: "local.device-canvas.android-stream.\(serial)", qos: .userInitiated)
        workerQueue = DispatchQueue(label: "local.device-canvas.scrcpy-worker.\(serial)", qos: .userInitiated)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !isActive else {
                return
            }
            isActive = true
            startSession()
        }
    }

    func stop(cancelTouch: Bool = false) {
        queue.sync {
            if cancelTouch, lastVideoSize.width > 0, lastVideoSize.height > 0 {
                _ = sendControlNow(touchMessage(
                    action: 3,
                    position: ScrcpyPosition(
                        x: 0,
                        y: 0,
                        width: UInt16(lastVideoSize.width),
                        height: UInt16(lastVideoSize.height)
                    ),
                    pressure: 0
                ))
            }
            isActive = false
            generation += 1
            closeConnection()
        }
    }

    func injectTouch(action: UInt8, position: ScrcpyPosition, pressure: Float) {
        sendControl(touchMessage(action: action, position: position, pressure: pressure))
    }

    private func touchMessage(action: UInt8, position: ScrcpyPosition, pressure: Float) -> Data {
        var message = Data([2, action])
        message.appendBigEndian(UInt64(bitPattern: -2))
        message.appendBigEndian(position.x)
        message.appendBigEndian(position.y)
        message.appendBigEndian(position.width)
        message.appendBigEndian(position.height)
        message.appendBigEndian(UInt16(max(0, min(1, pressure)) * Float(UInt16.max)))
        message.appendBigEndian(UInt32(0))
        message.appendBigEndian(UInt32(0))
        return message
    }

    func injectBack(action: UInt8) {
        sendControl(Data([4, action]))
    }

    func injectKeycode(action: UInt8, keycode: UInt32, repeatCount: UInt32, metastate: UInt32) {
        var message = Data([0, action])
        message.appendBigEndian(keycode)
        message.appendBigEndian(repeatCount)
        message.appendBigEndian(metastate)
        sendControl(message)
    }

    func injectText(_ text: String) {
        var payload = Data()
        for scalar in text.unicodeScalars {
            let bytes = String(scalar).utf8
            guard payload.count + bytes.count <= 300 else {
                break
            }
            payload.append(contentsOf: bytes)
        }
        var message = Data([1])
        message.appendBigEndian(UInt32(payload.count))
        message.append(payload)
        sendControl(message)
    }

    func injectScroll(position: ScrcpyPosition, horizontal: Float, vertical: Float) {
        var message = Data([3])
        message.appendBigEndian(position.x)
        message.appendBigEndian(position.y)
        message.appendBigEndian(position.width)
        message.appendBigEndian(position.height)
        message.appendBigEndian(scrollFixedPoint(horizontal))
        message.appendBigEndian(scrollFixedPoint(vertical))
        message.appendBigEndian(UInt32(0))
        sendControl(message)
    }

    private func startSession() {
        guard isActive, videoSocket == -1, controlSocket == -1 else {
            return
        }
        generation += 1
        let sessionGeneration = generation
        parser = H264AnnexBParser()
        pendingFrames.removeAll()
        isWaitingForKeyframe = false
        renderer.flush()

        workerQueue.async { [weak self] in
            self?.establishSession(generation: sessionGeneration)
        }
    }

    private func establishSession(generation sessionGeneration: Int) {
        guard let adbURL = AndroidSDK.adbURL,
              let installation = ScrcpyInstallation.current else {
            scheduleReconnect(generation: sessionGeneration)
            return
        }

        let scid = UInt32.random(in: 1...0x7fff_ffff)
        let scidString = String(format: "%08x", scid)
        let socketName = "scrcpy_\(scidString)"
        let remoteServerPath = "/data/local/tmp/scrcpy-server.jar"
        var forwardedPort: UInt16?
        var process: Process?
        var video: Int32 = -1
        var control: Int32 = -1
        var handedOff = false

        defer {
            if !handedOff {
                closeSocket(video)
                closeSocket(control)
                stopProcess(process)
                if let forwardedPort {
                    _ = try? AndroidSDK.runADB([
                        "-s", serial, "forward", "--remove", "tcp:\(forwardedPort)"
                    ])
                }
            }
        }

        do {
            _ = try AndroidSDK.runADB([
                "-s", serial, "push", installation.serverURL.path, remoteServerPath
            ], timeout: 30)
            guard isCurrent(sessionGeneration) else {
                return
            }

            let portOutput = try AndroidSDK.runADBText([
                "-s", serial, "forward", "tcp:0", "localabstract:\(socketName)"
            ])
            guard let port = UInt16(portOutput) else {
                throw AndroidEmulatorError.commandFailed(-1)
            }
            forwardedPort = port

            let serverProcess = Process()
            serverProcess.executableURL = adbURL
            serverProcess.arguments = [
                "-s", serial, "shell",
                "CLASSPATH=\(remoteServerPath)", "app_process", "/",
                "com.genymobile.scrcpy.Server", installation.version,
                "scid=\(scidString)", "log_level=warn", "audio=false",
                "tunnel_forward=true", "max_size=1600", "video_bit_rate=4000000",
                "clipboard_autosync=false", "send_device_meta=false",
                "send_frame_meta=false", "send_stream_meta=false", "send_dummy_byte=true"
            ]
            serverProcess.standardOutput = FileHandle.nullDevice
            serverProcess.standardError = FileHandle.nullDevice
            try serverProcess.run()
            process = serverProcess

            guard let videoSocket = connectVideoSocket(
                port: port,
                generation: sessionGeneration
            ) else {
                scheduleReconnect(generation: sessionGeneration)
                return
            }
            video = videoSocket
            guard let controlSocket = connectSocketWithRetry(
                port: port,
                generation: sessionGeneration
            ) else {
                scheduleReconnect(generation: sessionGeneration)
                return
            }
            control = controlSocket

            _ = try? AndroidSDK.runADB([
                "-s", serial, "forward", "--remove", "tcp:\(port)"
            ])
            forwardedPort = nil

            let didHandOff: Bool = queue.sync {
                guard isActive, self.generation == sessionGeneration else {
                    return false
                }
                self.videoSocket = video
                self.controlSocket = control
                self.serverProcess = process
                return true
            }
            handedOff = didHandOff
            guard handedOff else {
                return
            }

            readVideo(socket: video, generation: sessionGeneration)
            queue.async { [weak self] in
                self?.connectionEnded(generation: sessionGeneration)
            }
        } catch {
            scheduleReconnect(generation: sessionGeneration)
        }
    }

    private func readVideo(socket: Int32, generation sessionGeneration: Int) {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.recv(socket, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                return
            }
            let data = Data(bytes[0..<count])
            queue.async { [weak self] in
                self?.consume(data, generation: sessionGeneration)
            }
        }
    }

    private func connectionEnded(generation sessionGeneration: Int) {
        guard generation == sessionGeneration else {
            return
        }
        enqueue(parser.finishEndOfStream())
        closeConnection()
        guard isActive else {
            return
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startSession()
        }
    }

    private func consume(_ data: Data, generation sessionGeneration: Int) {
        guard isActive, generation == sessionGeneration else {
            return
        }
        enqueue(parser.append(data))
    }

    private func scheduleReconnect(generation sessionGeneration: Int) {
        queue.async { [weak self] in
            guard let self, isActive, generation == sessionGeneration else {
                return
            }
            closeConnection()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startSession()
            }
        }
    }

    private func isCurrent(_ sessionGeneration: Int) -> Bool {
        queue.sync {
            isActive && generation == sessionGeneration
        }
    }

    private func connectVideoSocket(port: UInt16, generation: Int) -> Int32? {
        for _ in 0..<100 where isCurrent(generation) {
            let socket = connectSocket(port: port)
            if socket >= 0 {
                setReceiveTimeout(socket, microseconds: 250_000)
                var dummy: UInt8 = 0
                let received = Darwin.recv(socket, &dummy, 1, 0)
                setReceiveTimeout(socket, microseconds: 0)
                if received == 1 {
                    return socket
                }
                closeSocket(socket)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func connectSocketWithRetry(port: UInt16, generation: Int) -> Int32? {
        for _ in 0..<100 where isCurrent(generation) {
            let socket = connectSocket(port: port)
            if socket >= 0 {
                return socket
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func connectSocket(port: UInt16) -> Int32 {
        let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            return -1
        }

        var noSignal: Int32 = 1
        Darwin.setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            closeSocket(fileDescriptor)
            return -1
        }
        return fileDescriptor
    }

    private func sendControl(_ message: Data) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            if !sendControlNow(message) {
                Darwin.shutdown(videoSocket, SHUT_RDWR)
            }
        }
    }

    private func sendControlNow(_ message: Data) -> Bool {
        guard controlSocket >= 0 else {
            return false
        }
        return message.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(
                    controlSocket,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset,
                    MSG_DONTWAIT
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    return false
                }
                offset += count
            }
            return true
        }
    }

    private func setReceiveTimeout(_ socket: Int32, microseconds: Int) {
        var timeout = timeval(
            tv_sec: microseconds / 1_000_000,
            tv_usec: Int32(microseconds % 1_000_000)
        )
        Darwin.setsockopt(
            socket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    private func scrollFixedPoint(_ value: Float) -> Int16 {
        let normalized = max(-1, min(1, value / 16))
        return Int16(normalized * Float(Int16.max))
    }

    private func closeConnection() {
        closeSocket(videoSocket)
        closeSocket(controlSocket)
        videoSocket = -1
        controlSocket = -1
        stopProcess(serverProcess)
        serverProcess = nil
        parser = H264AnnexBParser()
        pendingFrames.removeAll()
        isWaitingForKeyframe = false
        isDrainScheduled = false
        lastVideoSize = .zero
        DispatchQueue.main.async { [weak target] in
            target?.resetInputState()
        }
    }

    private func closeSocket(_ socket: Int32) {
        guard socket >= 0 else {
            return
        }
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func stopProcess(_ process: Process?) {
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func enqueue(_ frames: [H264Frame]) {
        recoverRendererIfNeeded()

        if let size = frames.last?.size, size != lastVideoSize {
            lastVideoSize = size
            DispatchQueue.main.async { [weak target] in
                target?.updateVideoSize(size)
            }
        }

        for frame in frames {
            if isWaitingForKeyframe {
                guard frame.isKeyframe else {
                    continue
                }
                isWaitingForKeyframe = false
            }
            pendingFrames.append(frame)
        }

        if pendingFrames.count > 300 {
            if let latestKeyframe = pendingFrames.lastIndex(where: \.isKeyframe), latestKeyframe > 0 {
                pendingFrames.removeFirst(latestKeyframe)
            }
            if pendingFrames.count > 300 {
                pendingFrames.removeAll()
                isWaitingForKeyframe = true
            }
        }

        drainPendingFrames()
    }

    private func drainPendingFrames() {
        recoverRendererIfNeeded()

        while renderer.isReadyForMoreMediaData, !pendingFrames.isEmpty {
            renderer.enqueue(pendingFrames.removeFirst().sampleBuffer)
        }

        guard !pendingFrames.isEmpty, !isDrainScheduled else {
            return
        }
        isDrainScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self else {
                return
            }
            isDrainScheduled = false
            drainPendingFrames()
        }
    }

    private func recoverRendererIfNeeded() {
        guard renderer.status == .failed else {
            return
        }

        renderer.flush()
        pendingFrames.removeAll()
        isWaitingForKeyframe = true
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

private struct H264Frame {
    let sampleBuffer: CMSampleBuffer
    let isKeyframe: Bool
    let size: CGSize
}

private struct H264AnnexBParser {
    private var buffer: [UInt8] = []
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var accessUnit: [Data] = []

    mutating func append(_ data: Data) -> [H264Frame] {
        buffer.append(contentsOf: data)
        var frames: [H264Frame] = []

        while let first = startCode(from: 0) {
            if first.index > 0 {
                buffer.removeFirst(first.index)
            }

            guard let next = startCode(from: first.length) else {
                break
            }

            let unit = Data(buffer[first.length..<next.index])
            let startsNewAccessUnit = startsNewAccessUnit(at: next)
            buffer.removeFirst(next.index)

            if let frame = process(unit) {
                frames.append(frame)
            }
            if startsNewAccessUnit, let frame = finishAccessUnit() {
                frames.append(frame)
            }
        }

        if startCode(from: 0) == nil, buffer.count > 1_048_576 {
            buffer.removeAll(keepingCapacity: true)
        }

        return frames
    }

    mutating func finishEndOfStream() -> [H264Frame] {
        var frames: [H264Frame] = []

        if let first = startCode(from: 0), first.index + first.length < buffer.count {
            let unit = Data(buffer[(first.index + first.length)...])
            if let frame = process(unit) {
                frames.append(frame)
            }
        }
        buffer.removeAll(keepingCapacity: true)

        if let frame = finishAccessUnit() {
            frames.append(frame)
        }
        return frames
    }

    private func startCode(from startIndex: Int) -> (index: Int, length: Int)? {
        guard startIndex >= 0, startIndex + 2 < buffer.count else {
            return nil
        }

        for index in startIndex..<(buffer.count - 2) where buffer[index] == 0 && buffer[index + 1] == 0 {
            if buffer[index + 2] == 1 {
                return (index, 3)
            }
            if index + 3 < buffer.count, buffer[index + 2] == 0, buffer[index + 3] == 1 {
                return (index, 4)
            }
        }
        return nil
    }

    private mutating func process(_ unit: Data) -> H264Frame? {
        guard let firstByte = unit.first else {
            return nil
        }

        switch firstByte & 0x1f {
        case 7:
            let sample = finishAccessUnit()
            guard sequenceParameterSet != unit else {
                return sample
            }
            sequenceParameterSet = unit
            rebuildFormatDescription()
            return sample
        case 8:
            let sample = finishAccessUnit()
            guard pictureParameterSet != unit else {
                return sample
            }
            pictureParameterSet = unit
            rebuildFormatDescription()
            return sample
        case 1, 5:
            let sample = firstMacroblock(in: unit) == 0 ? finishAccessUnit() : nil
            accessUnit.append(unit)
            return sample
        case 9:
            return finishAccessUnit()
        default:
            break
        }

        return nil
    }

    private func startsNewAccessUnit(at startCode: (index: Int, length: Int)) -> Bool {
        let unitStart = startCode.index + startCode.length
        guard unitStart < buffer.count else {
            return false
        }

        let type = buffer[unitStart] & 0x1f
        guard type == 1 || type == 5 else {
            return [6, 7, 8, 9, 10, 11, 13, 14, 15, 18].contains(type)
        }

        return firstMacroblock(in: Data(buffer[unitStart...])) == 0
    }

    private func firstMacroblock(in unit: Data) -> UInt? {
        guard unit.count > 1 else {
            return nil
        }

        let bytes = Array(unit.dropFirst())
        var leadingZeroBits = 0
        var bitIndex = 0

        while bitIndex < bytes.count * 8 {
            let byte = bytes[bitIndex / 8]
            let bit = (byte >> (7 - bitIndex % 8)) & 1
            bitIndex += 1
            if bit == 1 {
                break
            }
            leadingZeroBits += 1
        }

        guard leadingZeroBits < UInt.bitWidth, bitIndex + leadingZeroBits <= bytes.count * 8 else {
            return nil
        }

        var suffix: UInt = 0
        for _ in 0..<leadingZeroBits {
            let byte = bytes[bitIndex / 8]
            suffix = (suffix << 1) | UInt((byte >> (7 - bitIndex % 8)) & 1)
            bitIndex += 1
        }
        return (UInt(1) << leadingZeroBits) - 1 + suffix
    }

    private mutating func finishAccessUnit() -> H264Frame? {
        guard !accessUnit.isEmpty else {
            return nil
        }

        defer { accessUnit.removeAll(keepingCapacity: true) }
        return makeSampleBuffer(from: accessUnit)
    }

    private mutating func rebuildFormatDescription() {
        guard let sequenceParameterSet, let pictureParameterSet else {
            return
        }

        var description: CMFormatDescription?
        let status = sequenceParameterSet.withUnsafeBytes { sequenceBytes in
            pictureParameterSet.withUnsafeBytes { pictureBytes in
                guard let sequenceBaseAddress = sequenceBytes.baseAddress,
                      let pictureBaseAddress = pictureBytes.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }

                let pointers = [
                    sequenceBaseAddress.assumingMemoryBound(to: UInt8.self),
                    pictureBaseAddress.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes = [sequenceParameterSet.count, pictureParameterSet.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }

        if status == noErr {
            formatDescription = description
        }
    }

    private func makeSampleBuffer(from units: [Data]) -> H264Frame? {
        guard let formatDescription else {
            return nil
        }

        var sampleData = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            sampleData.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            sampleData.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let copyStatus = sampleData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            return nil
        }

        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        let isKeyframe = units.contains { ($0.first ?? 0) & 0x1f == 5 }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) {
            let attachment = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyframe {
                CFDictionarySetValue(
                    attachment,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        return H264Frame(
            sampleBuffer: sampleBuffer,
            isKeyframe: isKeyframe,
            size: {
                let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
                return CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            }()
        )
    }
}
