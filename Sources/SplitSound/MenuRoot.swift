import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MenuRoot: View {
    @ObservedObject private var model = AppModel.shared
    @State private var query = ""

    var body: some View {
        let rows = model.visibleApps(matching: query)
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
            if model.visibleApps(matching: "").count > 10 {
                TextField("Search apps", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
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
                Text(model.apps.isEmpty
                    ? "Play audio in an app and it will show up here."
                    : "No matching apps.")
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
        .frame(height: min(280, max(36, CGFloat(max(rows.count, 1)) * (rows.contains(where: diverts) ? 58 : 32))))
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

    private func diverts(_ app: AudioApp) -> Bool {
        guard let uid = model.routes[app.id]?.deviceUID else { return false }
        return uid != model.defaultOutputUID && model.devices.contains { $0.uid == uid }
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
            if diverts {
                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel(Text(app.name))
            }
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

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.routes[app.id]?.volume ?? 1 },
            set: { model.setVolume(for: app, volume: $0) }
        )
    }

    private var diverts: Bool {
        guard let uid = model.routes[app.id]?.deviceUID else { return false }
        return uid != model.defaultOutputUID && model.devices.contains { $0.uid == uid }
    }

    private func deviceTitle(_ device: OutputDevice) -> String {
        guard device.uid == model.defaultOutputUID else { return device.name }
        return String(format: String(localized: "%@ (System)"), device.name)
    }
}
