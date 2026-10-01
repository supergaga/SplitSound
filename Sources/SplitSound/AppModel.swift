import AppKit
import Combine
import CoreAudio
import Foundation
import ServiceManagement

struct StoredRoute: Codable, Equatable, Sendable {
    var deviceUID: String
    var volume: Double
    var displayName: String
}

struct RowNote: Equatable, Sendable {
    var message: String
    var warning: Bool
}

private struct RouteAssignment: Equatable, Sendable {
    var key: String
    var processIDs: [AudioObjectID]
    var deviceUID: String
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
            engine.volume = item.volume
            engine.isPlaying = item.playing
            if !engine.isRunning || engine.processIDs != item.processIDs || engine.deviceUID != item.deviceUID {
                do {
                    try engine.restart(processIDs: item.processIDs, deviceUID: item.deviceUID)
                } catch {
                    snapshot.errors[item.key] = error.localizedDescription
                }
            }
            if engine.silenceHint { snapshot.silenceKeys.append(item.key) }
            if engine.formatProblem { snapshot.formatKeys.append(item.key) }
        }
        return snapshot
    }

    func setVolume(key: String, volume: Float) {
        queue.async {
            self.engines[key]?.volume = volume
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var devices: [OutputDevice] = []
    @Published var apps: [AudioApp] = []
    @Published var routes: [String: StoredRoute] = [:]
    @Published var defaultOutputUID = ""
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

    private var watchesDevices: Bool {
        routes.contains { $0.value.deviceUID != defaultOutputUID }
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
                if changed || (readingNotes && self.watchesDevices) {
                    self.reconcile()
                }
                self.updatePolling()
            }
        }
    }

    private func updatePolling() {
        guard watchesDevices else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                AppModel.shared.performRefresh(readingNotes: true)
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

    func setOutput(for app: AudioApp, deviceUID: String?) {
        if let deviceUID {
            routes[app.id] = StoredRoute(
                deviceUID: deviceUID,
                volume: routes[app.id]?.volume ?? 1,
                displayName: app.name
            )
        } else {
            routes[app.id] = nil
        }
        saveTask?.cancel()
        save()
        reconcile()
        updatePolling()
    }

    func setVolume(for app: AudioApp, volume: Double) {
        guard var route = routes[app.id] else { return }
        route.volume = min(1, max(0, volume))
        routes[app.id] = route
        hub.setVolume(key: app.id, volume: Float(route.volume))
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

    func visibleApps(matching query: String) -> [AudioApp] {
        var rows = apps.filter { showSystemProcesses || !$0.isSystem }
        let known = Set(rows.map(\.id))
        for (key, route) in routes where !known.contains(key) {
            rows.append(AudioApp(
                id: key,
                name: route.displayName,
                bundlePath: nil,
                processIDs: [],
                isPlaying: false,
                isSystem: false
            ))
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            rows = rows.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        return rows.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            let leftRouted = routes[lhs.id] != nil
            let rightRouted = routes[rhs.id] != nil
            if leftRouted != rightRouted { return leftRouted }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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
            if !connected.contains(route.deviceUID) {
                immediate[key] = RowNote(
                    message: String(localized: "The device is offline. Audio is using the system output until it reconnects."),
                    warning: true
                )
                continue
            }
            guard let app = apps.first(where: { $0.id == key }), !app.processIDs.isEmpty else { continue }
            if route.deviceUID == defaultOutputUID { continue }
            desired.append(RouteAssignment(
                key: key,
                processIDs: app.processIDs,
                deviceUID: route.deviceUID,
                volume: Float(route.volume),
                playing: app.isPlaying
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
