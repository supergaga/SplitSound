import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Equatable, Sendable {
    let uid: String
    let name: String
    let transport: UInt32
    let objectID: AudioObjectID
    var id: String { uid }
}

struct AudioApp: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var bundlePath: String?
    var processIDs: [AudioObjectID]
    var isPlaying: Bool
    var isSystem: Bool
}

struct AudioError: LocalizedError, Sendable {
    let status: OSStatus

    var errorDescription: String? {
        String(format: String(localized: "Could not change the audio route (%@)."), Self.code(status))
    }

    private static func code(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return String(status)
    }
}

enum AudioSystem {
    static let bundleIdentifier = "app.splitsound.mac"
    static let aggregatePrefix = "app.splitsound.aggregate."
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func outputDevices() throws -> [OutputDevice] {
        var devices: [OutputDevice] = []
        for id in try objectIDs(system, selector: kAudioHardwarePropertyDevices) {
            guard !(try objectIDs(id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)).isEmpty else {
                continue
            }
            let uid = try string(id, selector: kAudioDevicePropertyDeviceUID)
            guard !uid.hasPrefix(aggregatePrefix) else { continue }
            let name = try string(id, selector: kAudioObjectPropertyName)
            let transport = (try? uint32(id, selector: kAudioDevicePropertyTransportType)) ?? 0
            devices.append(OutputDevice(uid: uid, name: name, transport: transport, objectID: id))
        }
        return devices.sorted { lhs, rhs in
            let leftBuiltIn = lhs.transport == kAudioDeviceTransportTypeBuiltIn
            let rightBuiltIn = rhs.transport == kAudioDeviceTransportTypeBuiltIn
            if leftBuiltIn != rightBuiltIn { return leftBuiltIn }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func defaultOutputUID() throws -> String {
        try string(try outputDeviceID(kAudioHardwarePropertyDefaultOutputDevice), selector: kAudioDevicePropertyDeviceUID)
    }

    /// Alert sounds, including typing beeps, use a separate device from normal playback.
    static func alignAlertSounds(withOutput uid: String) throws {
        guard let device = try outputDevices().first(where: { $0.uid == uid }) else { return }
        let alerts = try? outputDeviceID(kAudioHardwarePropertyDefaultSystemOutputDevice)
        guard alerts != device.objectID else { return }
        try setOutputDevice(device.objectID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    static func setDefaultOutput(uid: String) throws {
        guard let device = try outputDevices().first(where: { $0.uid == uid }) else {
            throw AudioError(status: kAudioHardwareBadDeviceError)
        }
        try setOutputDevice(device.objectID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setOutputDevice(device.objectID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    private static func outputDeviceID(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var address = propertyAddress(selector)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &value)
        guard status == noErr, value != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioError(status: status)
        }
        return value
    }

    private static func setOutputDevice(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        var deviceID = id
        var address = propertyAddress(selector)
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(system, &address, 0, nil, size, &deviceID)
        guard status == noErr else { throw AudioError(status: status) }
    }

    static func audioApps() -> [AudioApp] {
        guard let processObjects = try? objectIDs(system, selector: kAudioHardwarePropertyProcessObjectList) else {
            return []
        }

        struct Bucket {
            var name: String
            var bundlePath: String?
            var processIDs: [AudioObjectID]
            var isPlaying: Bool
            var isSystem: Bool
        }

        var buckets: [String: Bucket] = [:]
        let ownPID = getpid()

        for object in processObjects {
            guard let pid = try? pid(object), pid != ownPID else { continue }
            let processBundle = try? string(object, selector: kAudioProcessPropertyBundleID)
            if processBundle == bundleIdentifier { continue }

            let playing = ((try? uint32(object, selector: kAudioProcessPropertyIsRunningOutput)) ?? 0) != 0
            let exe = executablePath(pid: pid)
            let appPath = exe.flatMap(outermostApp)
            let appBundle = appPath.flatMap { Bundle(url: URL(fileURLWithPath: $0))?.bundleIdentifier }
            if appBundle == bundleIdentifier { continue }

            let key: String
            let name: String
            let systemProcess: Bool
            if let appPath, let appBundle {
                key = appBundle
                name = displayName(appPath)
                systemProcess = isSystemLocation(appPath)
            } else if let appPath {
                key = "path:" + appPath
                name = displayName(appPath)
                systemProcess = isSystemLocation(appPath)
            } else if let processBundle, !processBundle.isEmpty {
                key = processBundle
                name = processBundle
                systemProcess = true
            } else {
                continue
            }

            var bucket = buckets[key] ?? Bucket(
                name: name,
                bundlePath: appPath,
                processIDs: [],
                isPlaying: false,
                isSystem: systemProcess
            )
            bucket.processIDs.append(object)
            bucket.isPlaying = bucket.isPlaying || playing
            if bucket.bundlePath == nil { bucket.bundlePath = appPath }
            buckets[key] = bucket
        }

        return buckets.map { key, bucket in
            AudioApp(
                id: key,
                name: bucket.name,
                bundlePath: bucket.bundlePath,
                processIDs: bucket.processIDs.sorted(),
                isPlaying: bucket.isPlaying,
                isSystem: bucket.isSystem
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func objectIDs(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw AudioError(status: sizeStatus) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values)
        guard status == noErr else { throw AudioError(status: status) }
        return values
    }

    static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw AudioError(status: status) }
        return value.takeRetainedValue() as String
    }

    static func format(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioError(status: status) }
        return value
    }

    private static func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioError(status: status) }
        return value
    }

    private static func pid(_ object: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioError(status: status) }
        return value
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Helpers and XPC services live inside the app bundle, so the outer `.app` owns their audio.
    private static func outermostApp(_ path: String) -> String? {
        var current = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + part
            if part.lowercased().hasSuffix(".app") { return current }
        }
        return nil
    }

    private static func isSystemLocation(_ path: String) -> Bool {
        path.hasPrefix("/System/Library/")
            || path.hasPrefix("/usr/")
            || path.hasPrefix("/Library/Apple/")
            || path.hasPrefix("/Library/SystemExtensions/")
    }

    private static func displayName(_ appPath: String) -> String {
        let url = URL(fileURLWithPath: appPath)
        if let bundle = Bundle(url: url) {
            let display = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            let name = bundle.localizedInfoDictionary?["CFBundleName"] as? String
            let fallbackDisplay = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let fallbackName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let display, !display.isEmpty { return display }
            if let name, !name.isEmpty { return name }
            if let fallbackDisplay, !fallbackDisplay.isEmpty { return fallbackDisplay }
            if let fallbackName, !fallbackName.isEmpty { return fallbackName }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
