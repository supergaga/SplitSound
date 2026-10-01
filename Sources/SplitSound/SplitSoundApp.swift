import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

@main
struct SplitSoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuRoot()
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .accessibilityLabel(Text("Split Sound"))
        }
        .menuBarExtraStyle(.window)
    }
}
