import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MenuRoot: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        let rows = model.visibleApps()
        VStack(alignment: .leading, spacing: 12) {
            header
            labeledPicker(
                title: "System Output",
                selection: Binding(
                    get: { model.defaultOutputUID },
                    set: { model.setDefaultOutput($0) }
                ),
                emptyTitle: "No output devices"
            ) {
                ForEach(model.devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            appList(rows)
            settings
        }
        .padding(12)
        .frame(width: 248)
        .onAppear { model.noteMenuOpened() }
    }

    private var header: some View {
        HStack {
            Text("Split Sound")
                .font(.headline)
            Spacer()
            Button("Quit") { model.quit() }
                .controlSize(.small)
        }
    }

    private func appList(_ rows: [AudioApp]) -> some View {
        ScrollView {
            if rows.isEmpty {
                Text("Play audio in an app and it will show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { app in
                        AppRouteRow(app: app)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: min(320, max(64, CGFloat(max(rows.count, 1)) * 86)))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let banner = model.banner {
                Text(banner)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show system processes", isOn: Binding(
                get: { model.showSystemProcesses },
                set: { model.setShowSystemProcesses($0) }
            ))
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Button("Recording Permission...") { model.openPrivacySettings() }
                .controlSize(.small)
        }
        .font(.caption)
        .toggleStyle(.checkbox)
    }

    private func labeledPicker<Options: View>(
        title: LocalizedStringKey,
        selection: Binding<String>,
        emptyTitle: LocalizedStringKey,
        @ViewBuilder options: () -> Options
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                if model.devices.isEmpty {
                    Text(emptyTitle).tag("")
                }
                options()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            VolumeSlider(value: Binding(
                get: { model.systemVolume },
                set: { model.setSystemVolume($0) }
            ))
        }
    }
}

private struct VolumeSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: 0...1)
                .controlSize(.mini)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private struct AppRouteRow: View {
    @ObservedObject private var model = AppModel.shared
    let app: AudioApp

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                appIcon
                    .help(app.name)
                    .accessibilityLabel(Text(app.name))
                Picker("Output device", selection: outputBinding) {
                    Text("Follow System").tag("")
                    ForEach(model.devices) { device in
                        Text(deviceTitle(device)).tag(device.uid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("EQ", selection: eqBinding) {
                ForEach(EQPreset.allCases) { preset in
                    Text(preset.label).tag(preset.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            VolumeSlider(value: appVolumeBinding)
            if let note = model.notes[app.id] {
                Text(note.message)
                    .font(.caption2)
                    .foregroundStyle(note.warning ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            iconImage
                .frame(width: 20, height: 20)
                .opacity(app.processIDs.isEmpty ? 0.4 : 1)
            if app.isPlaying {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(Text("Playing"))
            }
        }
        .frame(width: 22, height: 22)
    }

    @ViewBuilder
    private var iconImage: some View {
        #if os(macOS)
        if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .padding(2)
                .foregroundStyle(.secondary)
        }
        #else
        Image(systemName: "app.fill")
            .resizable()
            .padding(2)
            .foregroundStyle(.secondary)
        #endif
    }

    private var outputBinding: Binding<String> {
        Binding(
            get: { model.routes[app.id]?.deviceUID ?? "" },
            set: { model.setOutput(for: app, deviceUID: $0.isEmpty ? nil : $0) }
        )
    }

    private var appVolumeBinding: Binding<Double> {
        let deviceUID = model.routes[app.id]?.deviceUID ?? ""
        if deviceUID.isEmpty {
            return Binding(
                get: { model.routes[app.id]?.volume ?? 1 },
                set: { model.setAppVolume(for: app, volume: $0) }
            )
        }
        return Binding(
            get: { model.deviceVolume(uid: deviceUID) },
            set: { model.setDeviceVolume(uid: deviceUID, value: $0) }
        )
    }

    private var eqBinding: Binding<String> {
        Binding(
            get: { model.routes[app.id]?.eq ?? EQPreset.off.rawValue },
            set: { model.setEQ(for: app, preset: $0) }
        )
    }

    private func deviceTitle(_ device: OutputDevice) -> String {
        guard device.uid == model.defaultOutputUID else { return device.name }
        return String(format: String(localized: "%@ (System)"), device.name)
    }
}
