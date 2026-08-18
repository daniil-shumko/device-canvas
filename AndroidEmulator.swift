import AppKit
import AVFoundation
import Darwin
import Foundation
import SwiftUI

struct AndroidEmulatorRecord: Sendable {
    let serial: String
    let name: String
    let runtime: String
    let recordingSize: String
}

enum AndroidEmulatorError: LocalizedError {
    case commandFailed(Int32)
    case commandTimedOut

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status):
            "adb exited with status \(status)"
        case .commandTimedOut:
            "adb timed out"
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

    static func runADB(_ arguments: [String]) throws -> Data {
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
        guard termination.wait(timeout: .now() + 5) == .success else {
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

enum AndroidEmulatorDiscovery {
    static func runningEmulators() async throws -> [AndroidEmulatorRecord] {
        guard AndroidSDK.adbURL != nil else {
            return []
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
                let sizeOutput = try AndroidSDK.runADBText([
                    "-s", serial, "shell", "wm", "size"
                ])

                emulators.append(AndroidEmulatorRecord(
                    serial: serial,
                    name: avdName.replacingOccurrences(of: "_", with: " "),
                    runtime: runtime,
                    recordingSize: preferredRecordingSize(from: sizeOutput)
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

    private static func preferredRecordingSize(from output: String) -> String {
        guard let field = output.split(whereSeparator: \Character.isWhitespace).reversed().first(where: {
            $0.contains("x")
        }) else {
            return "720x1280"
        }

        let dimensions = field.split(separator: "x", maxSplits: 1)
        guard dimensions.count == 2,
              let sourceWidth = Int(dimensions[0]),
              let sourceHeight = Int(dimensions[1]) else {
            return "720x1280"
        }

        let maximumDimension = 1600.0
        let scale = min(1, maximumDimension / Double(max(sourceWidth, sourceHeight)))
        let width = max(16, Int((Double(sourceWidth) * scale / 16).rounded()) * 16)
        let height = max(16, Int((Double(sourceHeight) * scale / 16).rounded()) * 16)
        return "\(width)x\(height)"
    }
}

struct AndroidEmulatorView: NSViewRepresentable {
    let serial: String
    let recordingSize: String

    func makeNSView(context: Context) -> AndroidEmulatorScreenView {
        AndroidEmulatorScreenView(serial: serial, recordingSize: recordingSize)
    }

    func updateNSView(_ nsView: AndroidEmulatorScreenView, context: Context) {}

    static func dismantleNSView(_ nsView: AndroidEmulatorScreenView, coordinator: ()) {
        nsView.stop()
    }
}

final class AndroidEmulatorScreenView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var stream: AndroidEmulatorStream!

    init(serial: String, recordingSize: String) {
        super.init(frame: .zero)

        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        wantsLayer = true
        layer = displayLayer

        stream = AndroidEmulatorStream(
            serial: serial,
            recordingSize: recordingSize,
            renderer: displayLayer.sampleBufferRenderer
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

    func stop() {
        stream.stop()
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
}

private final class AndroidEmulatorStream: @unchecked Sendable {
    private let serial: String
    private let recordingSize: String
    private let renderer: AVSampleBufferVideoRenderer
    private let queue: DispatchQueue
    private let readerQueue: DispatchQueue
    private var parser = H264AnnexBParser()
    private var process: Process?
    private var outputHandle: FileHandle?
    private var isActive = false
    private var pendingFrames: [H264Frame] = []
    private var isWaitingForKeyframe = false
    private var isDrainScheduled = false
    private var needsBootstrap = true
    private var processGeneration = 0

    init(serial: String, recordingSize: String, renderer: AVSampleBufferVideoRenderer) {
        self.serial = serial
        self.recordingSize = recordingSize
        self.renderer = renderer
        queue = DispatchQueue(label: "local.device-canvas.android-stream.\(serial)", qos: .userInitiated)
        readerQueue = DispatchQueue(label: "local.device-canvas.android-reader.\(serial)", qos: .userInitiated)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !isActive else {
                return
            }
            isActive = true
            startProcess()
        }
    }

    func stop() {
        queue.sync {
            isActive = false
            processGeneration += 1
            let runningProcess = process
            outputHandle = nil
            process = nil

            if let runningProcess, runningProcess.isRunning {
                runningProcess.terminate()
                let deadline = Date().addingTimeInterval(1)
                while runningProcess.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if runningProcess.isRunning {
                    Darwin.kill(runningProcess.processIdentifier, SIGKILL)
                    runningProcess.waitUntilExit()
                }
            }

            parser = H264AnnexBParser()
            pendingFrames.removeAll()
            isWaitingForKeyframe = false
            isDrainScheduled = false
        }
    }

    private func startProcess() {
        guard isActive, process == nil, let adbURL = AndroidSDK.adbURL else {
            return
        }

        parser = H264AnnexBParser()
        processGeneration += 1
        let generation = processGeneration
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = adbURL
        process.arguments = [
            "-s", serial,
            "exec-out", "screenrecord",
            "--output-format=h264",
            "--size", recordingSize,
            "--bit-rate", "4M",
            "--time-limit", needsBootstrap ? "1" : "0",
            "-"
        ]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        let outputHandle = standardOutput.fileHandleForReading
        self.process = process
        self.outputHandle = outputHandle

        do {
            try process.run()
            readerQueue.async { [weak self, weak process] in
                while true {
                    let data = outputHandle.readData(ofLength: 64 * 1024)
                    guard !data.isEmpty else {
                        break
                    }
                    self?.queue.async { [weak self] in
                        self?.consume(data, generation: generation)
                    }
                }

                self?.queue.async { [weak self, weak process] in
                    self?.finishProcess(process, generation: generation)
                }
            }
        } catch {
            self.outputHandle = nil
            self.process = nil
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startProcess()
            }
        }
    }

    private func finishProcess(_ finishedProcess: Process?, generation: Int) {
        guard process === finishedProcess, processGeneration == generation else {
            return
        }

        enqueue(parser.finishEndOfStream())
        outputHandle = nil
        process = nil

        guard isActive else {
            return
        }

        let restartDelay = needsBootstrap ? DispatchTimeInterval.nanoseconds(0) : .seconds(1)
        needsBootstrap = false
        queue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            self?.startProcess()
        }
    }

    private func consume(_ data: Data, generation: Int) {
        guard isActive, processGeneration == generation else {
            return
        }
        enqueue(parser.append(data))
    }

    private func enqueue(_ frames: [H264Frame]) {
        recoverRendererIfNeeded()

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

private struct H264Frame {
    let sampleBuffer: CMSampleBuffer
    let isKeyframe: Bool
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
            sequenceParameterSet = unit
            rebuildFormatDescription()
            return sample
        case 8:
            let sample = finishAccessUnit()
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
        }

        return H264Frame(
            sampleBuffer: sampleBuffer,
            isKeyframe: units.contains { ($0.first ?? 0) & 0x1f == 5 }
        )
    }
}
