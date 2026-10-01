import AppKit
import Combine
import CoreAudio
import Foundation
import ServiceManagement

struct StoredRoute: Codable, Equatable, Sendable {
    var deviceUID: String
    var displayName: String
    var eq: String
    /// 1 matches the Sound settings volume. Lower values only affect this app.
    var volume: Double

    init(deviceUID: String, displayName: String, eq: String = EQPreset.off.rawValue, volume: Double = 1) {
        self.deviceUID = deviceUID
        self.displayName = displayName
        self.eq = eq
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try container.decode(String.self, forKey: .deviceUID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? deviceUID
        eq = try container.decodeIfPresent(String.self, forKey: .eq) ?? EQPreset.off.rawValue
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceUID, forKey: .deviceUID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(eq, forKey: .eq)
        try container.encode(volume, forKey: .volume)
    }

    private enum CodingKeys: String, CodingKey {
        case deviceUID, displayName, eq, volume
    }

    var needsProcessing: Bool {
        !deviceUID.isEmpty || eq != EQPreset.off.rawValue || abs(volume - 1) > 0.005
    }
}

struct RowNote: Equatable, Sendable {
    var message: String
    var warning: Bool
}

private struct RouteAssignment: Equatable, Sendable {
    var key: String
    var processIDs: [AudioObjectID]
    var deviceUID: String
    var eq: String
    var volume: Float
    var playing: Bool
}

private struct RouteSnapshot: Sendable {
    var errors: [String: String] = [:]
    var silenceKeys: [String] = []
    var formatKeys: [String] = []
}

private struct SettingsFile: Codable {
    var routes: [String: StoredRoute] = [:]
    var showSystemProcesses = false
}

private final class EngineHub: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.splitsound.engines")
    private var engines: [String: RouteEngine] = [:]

    func prepare() {
        queue.sync {
            var allowed: UInt32 = 0
            var address = AudioSystem.propertyAddress(kAudioHardwarePropertyHogModeIsAllowed)
            let size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(AudioSystem.system, &address, 0, nil, size, &allowed)
            RouteEngine.destroyOrphans()
        }
    }

    func apply(_ desired: [RouteAssignment]) async -> RouteSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.applyOnQueue(desired))
            }
        }
    }

    func shutdown() {
        queue.sync {
            for engine in engines.values { engine.stop() }
            engines.removeAll()
        }
    }

    private func applyOnQueue(_ desired: [RouteAssignment]) -> RouteSnapshot {
        let wanted = Set(desired.map(\.key))
        for key in engines.keys where !wanted.contains(key) {
            engines[key]?.stop()
            engines[key] = nil
        }

        var snapshot = RouteSnapshot()
        for item in desired {
            let engine = engines[item.key] ?? RouteEngine(
                key: item.key,
                processIDs: item.processIDs,
                deviceUID: item.deviceUID
            )
            engines[item.key] = engine
            engine.isPlaying = item.playing
            engine.volume = item.volume
            if !engine.isRunning || engine.processIDs != item.processIDs || engine.deviceUID != item.deviceUID {
                do {
                    try engine.restart(processIDs: item.processIDs, deviceUID: item.deviceUID)
                } catch {
                    snapshot.errors[item.key] = error.localizedDescription
                }
            }
            engine.setEQ(item.eq)
            if engine.silenceHint { snapshot.silenceKeys.append(item.key) }
            if engine.formatProblem { snapshot.formatKeys.append(item.key) }
        }
        return snapshot
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var devices: [OutputDevice] = []
    @Published var apps: [AudioApp] = []
    @Published var routes: [String: StoredRoute] = [:]
    @Published var defaultOutputUID = ""
    @Published var systemVolume: Double = 1
    @Published var showSystemProcesses = false
    @Published var launchAtLogin = false
    @Published var notes: [String: RowNote] = [:]
    @Published var banner: String?

    private let hub = EngineHub()
    private var started = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var timer: Timer?
    private var scanGeneration = 0
    private var reconcileGeneration = 0
    private var listenerTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var volumeWatch = AudioObjectID(kAudioObjectUnknown)
    private var volumeWatchAddress = AudioObjectPropertyAddress()
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private let scanQueue = DispatchQueue(label: "app.splitsound.scan")

    private var settingsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SplitSound/routes.json")
    }

    private init() {
        load()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)
        hub.prepare()
        installListeners()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in
                AppModel.shared.performRefresh(readingNotes: true)
            }
        }
        performRefresh(readingNotes: false)
    }

    /// The panel was opened. Refresh once instead of polling while it stays closed.
    func noteMenuOpened() {
        performRefresh(readingNotes: true)
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        listenerTask?.cancel()
        saveTask?.cancel()
        save()
        hub.shutdown()
    }

    private func scheduleRefresh() {
        listenerTask?.cancel()
        listenerTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            performRefresh(readingNotes: false)
        }
    }

    private func performRefresh(readingNotes: Bool) {
        scanGeneration += 1
        let token = scanGeneration
        scanQueue.async {
            let devices = (try? AudioSystem.outputDevices()) ?? []
            let apps = AudioSystem.audioApps()
            let defaultUID = (try? AudioSystem.defaultOutputUID()) ?? ""
            let systemVolume = defaultUID.isEmpty ? 1 : Double(AudioSystem.outputVolume(uid: defaultUID))
            if !defaultUID.isEmpty {
                try? AudioSystem.alignAlertSounds(withOutput: defaultUID)
            }
            DispatchQueue.main.async {
                guard token == self.scanGeneration else { return }
                let changed = devices != self.devices || apps != self.apps || defaultUID != self.defaultOutputUID
                if devices != self.devices { self.devices = devices }
                if apps != self.apps {
                    self.apps = apps
                    self.refreshStoredNames()
                }
                if defaultUID != self.defaultOutputUID { self.defaultOutputUID = defaultUID }
                if abs(systemVolume - self.systemVolume) > 0.005 { self.systemVolume = systemVolume }
                self.watchSystemVolume(uid: defaultUID)
                if changed || (readingNotes && !self.routes.isEmpty) {
                    self.reconcile()
                }
            }
        }
    }

    func setDefaultOutput(_ uid: String) {
        do {
            try AudioSystem.setDefaultOutput(uid: uid)
            defaultOutputUID = uid
            banner = nil
            reconcile()
        } catch {
            banner = error.localizedDescription
        }
    }

    private func watchSystemVolume(uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }),
              var listenerAddress = AudioSystem.volumeListenerAddress(for: device.objectID) else { return }
        guard device.objectID != volumeWatch || listenerAddress.mSelector != volumeWatchAddress.mSelector else { return }
        if volumeWatch != AudioObjectID(kAudioObjectUnknown), let volumeListener {
            var previous = volumeWatchAddress
            AudioObjectRemovePropertyListenerBlock(volumeWatch, &previous, DispatchQueue.main, volumeListener)
        }
        guard AudioObjectHasProperty(device.objectID, &listenerAddress) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                guard !AppModel.shared.defaultOutputUID.isEmpty else { return }
                let value = Double(AudioSystem.outputVolume(uid: AppModel.shared.defaultOutputUID))
                if abs(value - AppModel.shared.systemVolume) > 0.005 {
                    AppModel.shared.systemVolume = value
                }
            }
        }
        volumeListener = block
        volumeWatch = device.objectID
        volumeWatchAddress = listenerAddress
        AudioObjectAddPropertyListenerBlock(device.objectID, &listenerAddress, DispatchQueue.main, block)
    }

    func setSystemVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        systemVolume = clamped
        guard !defaultOutputUID.isEmpty else { return }
        AudioSystem.setOutputVolume(uid: defaultOutputUID, value: Float(clamped))
    }

    func setOutput(for app: AudioApp, deviceUID: String?) {
        updateRoute(for: app, deviceUID: deviceUID ?? "", eq: routes[app.id]?.eq ?? EQPreset.off.rawValue)
    }

    func setEQ(for app: AudioApp, preset: String) {
        updateRoute(for: app, deviceUID: routes[app.id]?.deviceUID ?? "", eq: preset)
    }

    /// The slider uses the same 0...1 scale as Control Center. 100% of an app is the current system level, not a second louder ceiling.
    func displayedAppVolume(for app: AudioApp) -> Double {
        let gain = routes[app.id]?.volume ?? 1
        return min(1, max(0, systemVolume * gain))
    }

    func setDisplayedAppVolume(for app: AudioApp, shown: Double) {
        let shown = min(1, max(0, shown))
        if systemVolume < 0.02 {
            setSystemVolume(shown)
            setAppVolume(for: app, volume: 1)
            return
        }
        if shown > systemVolume + 0.015 {
            setSystemVolume(shown)
            setAppVolume(for: app, volume: 1)
        } else {
            setAppVolume(for: app, volume: shown / systemVolume)
        }
    }

    func setAppVolume(for app: AudioApp, volume: Double) {
        let clamped = min(1, max(0, volume))
        let deviceUID = routes[app.id]?.deviceUID ?? ""
        let eq = routes[app.id]?.eq ?? EQPreset.off.rawValue
        storeRoute(for: app, deviceUID: deviceUID, eq: eq, volume: clamped)
        scheduleSave()
        reconcile()
    }

    private func updateRoute(for app: AudioApp, deviceUID: String, eq: String) {
        storeRoute(for: app, deviceUID: deviceUID, eq: eq, volume: routes[app.id]?.volume ?? 1)
        saveTask?.cancel()
        save()
        reconcile()
    }

    private func storeRoute(for app: AudioApp, deviceUID: String, eq: String, volume: Double) {
        let unchanged = deviceUID.isEmpty && eq == EQPreset.off.rawValue && abs(volume - 1) <= 0.005
        if unchanged {
            routes[app.id] = nil
        } else {
            routes[app.id] = StoredRoute(deviceUID: deviceUID, displayName: app.name, eq: eq, volume: volume)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func setShowSystemProcesses(_ show: Bool) {
        showSystemProcesses = show
        save()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            banner = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            banner = String(localized: "Could not turn on launch at login. Move Split Sound into the Applications folder and try again.")
        }
    }

    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    func visibleApps() -> [AudioApp] {
        apps
            .filter { $0.isPlaying && (showSystemProcesses || !$0.isSystem) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func refreshStoredNames() {
        var changed = false
        for app in apps {
            guard var route = routes[app.id], route.displayName != app.name else { continue }
            route.displayName = app.name
            routes[app.id] = route
            changed = true
        }
        if changed { save() }
    }

    private func reconcile() {
        reconcileGeneration += 1
        let generation = reconcileGeneration
        var desired: [RouteAssignment] = []
        var immediate: [String: RowNote] = [:]
        let connected = Set(devices.map(\.uid))

        for (key, route) in routes {
            let followsSystem = route.deviceUID.isEmpty
            if !followsSystem && !connected.contains(route.deviceUID) {
                immediate[key] = RowNote(
                    message: String(localized: "The device is offline. Audio is using the system output until it reconnects."),
                    warning: true
                )
                continue
            }
            guard let app = apps.first(where: { $0.id == key }), app.isPlaying, !app.processIDs.isEmpty else { continue }
            let target = followsSystem ? defaultOutputUID : route.deviceUID
            let customEQ = route.eq != EQPreset.off.rawValue
            let customVolume = abs(route.volume - 1) > 0.005
            if target == defaultOutputUID && !customEQ && !customVolume { continue }
            desired.append(RouteAssignment(
                key: key,
                processIDs: app.processIDs,
                deviceUID: target,
                eq: route.eq,
                volume: Float(route.volume),
                playing: true
            ))
        }

        let captured = immediate
        Task {
            let snapshot = await hub.apply(desired)
            guard generation == self.reconcileGeneration else { return }
            var merged = captured
            for (key, message) in snapshot.errors {
                merged[key] = RowNote(message: message, warning: false)
            }
            for key in snapshot.formatKeys where merged[key] == nil {
                merged[key] = RowNote(
                    message: String(localized: "This device's audio format is not supported."),
                    warning: false
                )
            }
            for key in snapshot.silenceKeys where merged[key] == nil {
                merged[key] = RowNote(
                    message: String(localized: "No audio is coming through. Allow Split Sound under System Settings, Privacy & Security, Screen & System Audio Recording. Without permission, a routed app stays silent."),
                    warning: false
                )
            }
            if merged != self.notes { self.notes = merged }
        }
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in AppModel.shared.scheduleRefresh() }
        }
        listener = block
        let queue = DispatchQueue(label: "app.splitsound.hal")
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ]
        for selector in selectors {
            var address = AudioSystem.propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioSystem.system, &address, queue, block)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: settingsURL),
              let file = try? JSONDecoder().decode(SettingsFile.self, from: data) else { return }
        routes = file.routes
        showSystemProcesses = file.showSystemProcesses
    }

    private func save() {
        let directory = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SettingsFile(routes: routes, showSystemProcesses: showSystemProcesses)) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}
