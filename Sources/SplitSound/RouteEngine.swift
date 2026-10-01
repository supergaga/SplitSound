import CoreAudio
import Darwin
import Foundation

private struct StreamLayout {
    var channels: Int
    var bytesPerFrame: Int
    var nonInterleaved: Bool

    init(_ format: AudioStreamBasicDescription) {
        channels = max(1, Int(format.mChannelsPerFrame))
        bytesPerFrame = max(1, Int(format.mBytesPerFrame))
        nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }
}

private struct RouteLevels {
    var gain: Float = 1
    var heard: Int32 = 0
    var bail: Int32 = 0
    var calls: Int64 = 0
}

/// One app, muted on its normal output and played through a chosen device.
final class RouteEngine: @unchecked Sendable {
    let key: String
    private(set) var processIDs: [AudioObjectID]
    private(set) var deviceUID: String
    var isPlaying = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "app.splitsound.io", qos: .userInteractive)
    private let levels: UnsafeMutablePointer<RouteLevels>
    private let eq = UnsafeMutablePointer<EQRuntime>.allocate(capacity: 1)
    private var eqPreset = EQPreset.off.rawValue
    private var sampleRate: Double = 48_000
    private var startedAt = Date()

    init(key: String, processIDs: [AudioObjectID], deviceUID: String) {
        self.key = key
        self.processIDs = processIDs
        self.deviceUID = deviceUID
        levels = UnsafeMutablePointer<RouteLevels>.allocate(capacity: 1)
        levels.initialize(to: RouteLevels())
        eq.initialize(to: EQRuntime())
    }

    deinit {
        stop()
        levels.deinitialize(count: 1)
        levels.deallocate()
        eq.deinitialize(count: 1)
        eq.deallocate()
    }

    var volume: Float {
        get { levels.pointee.gain }
        set { levels.pointee.gain = min(1, max(0, newValue)) }
    }

    func setEQ(_ preset: String) {
        eqPreset = preset
        let filters = (EQPreset(rawValue: preset) ?? .off).filters(sampleRate: sampleRate)
        eq.pointee.load(filters)
    }

    var isRunning: Bool { ioProc != nil }

    var silenceHint: Bool {
        isRunning
            && isPlaying
            && levels.pointee.heard == 0
            && levels.pointee.bail == 0
            && levels.pointee.calls > 30
            && Date().timeIntervalSince(startedAt) > 2.5
    }

    var formatProblem: Bool {
        isRunning && levels.pointee.bail == 2 && levels.pointee.calls > 10
    }

    func start() throws {
        guard ioProc == nil, !processIDs.isEmpty else { return }
        do {
            try createTap()
            try createAggregate()
            try startIO()
            setEQ(eqPreset)
            startedAt = Date()
            levels.pointee.heard = 0
            levels.pointee.bail = 0
            levels.pointee.calls = 0
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            self.ioProc = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    func restart(processIDs: [AudioObjectID], deviceUID: String) throws {
        stop()
        self.processIDs = processIDs
        self.deviceUID = deviceUID
        try start()
    }

    static func destroyOrphans() {
        guard let ids = try? AudioSystem.objectIDs(AudioSystem.system, selector: kAudioHardwarePropertyDevices) else { return }
        for id in ids {
            guard let uid = try? AudioSystem.string(id, selector: kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(AudioSystem.aggregatePrefix) else { continue }
            AudioHardwareDestroyAggregateDevice(id)
        }
    }

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "SplitSound"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioError(status: status)
        }
        tapID = id
    }

    private func createAggregate() throws {
        let tapUID = try AudioSystem.string(tapID, selector: kAudioTapPropertyUID)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SplitSound",
            kAudioAggregateDeviceUIDKey: AudioSystem.aggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: deviceUID],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioError(status: status)
        }
        aggregateID = id
    }

    private func startIO() throws {
        let tapFormat = try AudioSystem.format(tapID, selector: kAudioTapPropertyFormat)
        let outputStreams = try AudioSystem.objectIDs(
            aggregateID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )
        guard isFloat32(tapFormat), let outputStream = outputStreams.first else {
            throw AudioError(status: kAudioHardwareUnsupportedOperationError)
        }
        let outputFormat = try AudioSystem.format(outputStream, selector: kAudioStreamPropertyVirtualFormat)
        guard isFloat32(outputFormat) else {
            throw AudioError(status: kAudioHardwareUnsupportedOperationError)
        }

        sampleRate = tapFormat.mSampleRate
        let tapLayout = StreamLayout(tapFormat)
        let outputLayout = StreamLayout(outputFormat)
        let levels = self.levels
        let eq = self.eq
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            render(
                input: inputData,
                tapLayout: tapLayout,
                output: outputData,
                outputLayout: outputLayout,
                levels: levels,
                eq: eq
            )
        }

        var proc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue, block)
        guard createStatus == noErr, let proc else { throw AudioError(status: createStatus) }
        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            throw AudioError(status: startStatus)
        }
        ioProc = proc
    }

    private func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
    }
}

private func render(
    input: UnsafePointer<AudioBufferList>,
    tapLayout: StreamLayout,
    output: UnsafeMutablePointer<AudioBufferList>,
    outputLayout: StreamLayout,
    levels: UnsafeMutablePointer<RouteLevels>,
    eq: UnsafeMutablePointer<EQRuntime>
) {
    let outputList = UnsafeMutableAudioBufferListPointer(output)
    let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    levels.pointee.calls += 1

    for buffer in outputList {
        if let data = buffer.mData {
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    let tapBuffers = tapLayout.nonInterleaved ? tapLayout.channels : 1
    let outputBuffers = outputLayout.nonInterleaved ? outputLayout.channels : 1
    guard inputList.count >= tapBuffers, outputList.count >= outputBuffers else {
        levels.pointee.bail = 2
        return
    }
    let inputOffset = inputList.count - tapBuffers
    let inputFrames = Int(inputList[inputOffset].mDataByteSize) / tapLayout.bytesPerFrame
    let outputFrames = Int(outputList[0].mDataByteSize) / outputLayout.bytesPerFrame
    let frames = min(inputFrames, outputFrames, 8192)
    guard frames > 0 else {
        levels.pointee.bail = 3
        return
    }
    levels.pointee.bail = 0

    var loudest: Float = 0
    for frame in 0..<frames {
        var left = tapSample(inputList, offset: inputOffset, layout: tapLayout, channel: 0, frame: frame)
        var right = tapLayout.channels > 1
            ? tapSample(inputList, offset: inputOffset, layout: tapLayout, channel: 1, frame: frame)
            : left
        left = eq.pointee.process(left: left)
        right = eq.pointee.process(right: right)
        let gain = levels.pointee.gain
        if outputLayout.channels == 1 {
            loudest = max(loudest, writeSample((left + right) * 0.5 * gain, to: outputList, layout: outputLayout, channel: 0, frame: frame))
        } else {
            loudest = max(loudest, writeSample(left * gain, to: outputList, layout: outputLayout, channel: 0, frame: frame))
            loudest = max(loudest, writeSample(right * gain, to: outputList, layout: outputLayout, channel: 1, frame: frame))
        }
    }
    if loudest > 0.01 {
        levels.pointee.heard = 1
    }
}

private func tapSample(
    _ list: UnsafeMutableAudioBufferListPointer,
    offset: Int,
    layout: StreamLayout,
    channel: Int,
    frame: Int
) -> Float {
    let sourceChannel = min(channel, layout.channels - 1)
    if layout.nonInterleaved {
        guard let data = list[offset + sourceChannel].mData else { return 0 }
        return data.assumingMemoryBound(to: Float.self)[frame]
    }
    guard let data = list[offset].mData else { return 0 }
    return data.assumingMemoryBound(to: Float.self)[frame * layout.channels + sourceChannel]
}

@discardableResult
private func writeSample(
    _ sample: Float,
    to list: UnsafeMutableAudioBufferListPointer,
    layout: StreamLayout,
    channel: Int,
    frame: Int
) -> Float {
    let value = min(1, max(-1, sample))
    if layout.nonInterleaved {
        guard channel < layout.channels, let data = list[channel].mData else { return 0 }
        data.assumingMemoryBound(to: Float.self)[frame] = value
    } else {
        guard let data = list[0].mData else { return 0 }
        data.assumingMemoryBound(to: Float.self)[frame * layout.channels + channel] = value
    }
    return abs(value)
}
