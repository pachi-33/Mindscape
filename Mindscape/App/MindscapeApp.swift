import AppKit
import SwiftUI

@MainActor
final class MindscapeAppDelegate: NSObject, NSApplicationDelegate {
    weak var updates: UpdateChecker?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let updates else { return .terminateNow }
        switch updates.evaluateExit(continueAfterCancellation: { canQuit in
            if !canQuit { UpdateWindowController.shared.show(checker: updates) }
            sender.reply(toApplicationShouldTerminate: canQuit)
        }) {
        case .allow: return .terminateNow
        case .cancelUpdateFirst: return .terminateLater
        case .stayOpen:
            UpdateWindowController.shared.show(checker: updates)
            return .terminateCancel
        }
    }
}

@main
struct MindscapeApp: App {
    @NSApplicationDelegateAdaptor(MindscapeAppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Mindscape", id: "main") {
            RootView()
                .environment(app)
                .onAppear { delegate.updates = app.updates }
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands(app: app)
        }

        Settings {
            SettingsView()
                .environment(app)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(app)
        } label: {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .accessibilityLabel("Mindscape")
        }
        .menuBarExtraStyle(.menu)
    }
}
