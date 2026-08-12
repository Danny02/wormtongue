import AppKit
import SwiftUI
import WormtongueCore

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.statusText)

        if let error = state.configError {
            Text(error)
        }

        switch state.phase {
        case .recording, .transcribing, .rewriting, .inserting:
            Button("Cancel") { state.cancel() }
                .keyboardShortcut(".")
        default:
            EmptyView()
        }

        Divider()

        if let last = state.history.first {
            Text("Last: \(last.modeName) · \(last.action.label)")
            Text(last.timings)
            Button("Re-insert last") { state.reinsert(last) }
        }
        if let revertable = state.revertable {
            Button("Revert last edit (\(revertable.action.label))") { state.revert(revertable) }
                .keyboardShortcut("z")
        }

        Divider()

        Button("Setup & Permissions…") { activateAndOpen(openWindow, WindowID.setup) }
        Button("History…") { activateAndOpen(openWindow, WindowID.history) }

        Divider()

        Button("Reload Config") { state.reloadConfig() }
        Button("Open Config Folder") {
            NSWorkspace.shared.open(ConfigStore.url.deletingLastPathComponent())
        }
        if case .failed = state.phase {
            Button("Clear Error") { state.dismissError() }
        }

        Divider()

        Button("Quit Wormtongue") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
