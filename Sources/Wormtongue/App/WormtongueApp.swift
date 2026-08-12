import AppKit
import SwiftUI

@main
struct WormtongueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.statusSymbol)
        }
        .menuBarExtraStyle(.menu)

        Window("Wormtongue Setup", id: WindowID.setup) {
            SetupView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Dictation History", id: WindowID.history) {
            HistoryView()
                .environmentObject(state)
        }
    }
}

enum WindowID {
    static let setup = "setup"
    static let history = "history"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement in Info.plist — keeps the app out
        // of the Dock and, more importantly, stops it stealing focus from the app
        // we are about to dictate into.
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Windows can only come forward if the app activates; an accessory app has to
/// ask for that explicitly.
@MainActor
func activateAndOpen(_ open: OpenWindowAction, _ id: String) {
    NSApp.activate(ignoringOtherApps: true)
    open(id: id)
}
