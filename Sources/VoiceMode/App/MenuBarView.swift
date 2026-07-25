import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.statusText)

        if !state.modelReady {
            Text("Whisper model loading…")
        }
        if let error = state.configError {
            Text(error)
        }

        Divider()

        if let last = state.history.first {
            Text("Last: \(last.modeName)\(last.contextSent ? " · context sent" : "")")
            Text(last.timings)
            Button("Re-insert last") { state.reinsert(last) }
        }

        Divider()

        Button("Setup & Permissions…") { activateAndOpen(openWindow, WindowID.setup) }
        Button("History…") { activateAndOpen(openWindow, WindowID.history) }

        Divider()

        Button("Reload Config") { state.reloadConfig() }
        Button("Open Config File") {
            NSWorkspace.shared.open(ConfigStore.url.deletingLastPathComponent())
        }
        if case .failed = state.phase {
            Button("Clear Error") { state.dismissError() }
        }

        Divider()

        Button("Quit VoiceMode") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
