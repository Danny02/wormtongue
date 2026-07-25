import SwiftUI
import VoiceModeCore

/// Last N dictations, with re-insert and re-run-under-a-different-mode. This is
/// the debugging surface: it shows what the transcript was, what the LLM did to
/// it, whether context left the machine, and where the latency went.
struct HistoryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.history.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "mic",
                    description: Text("Hold the hotkey and speak."))
            } else {
                List(state.history) { row(for: $0) }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private func row(for dictation: Dictation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(dictation.date, style: .time).font(.caption).foregroundStyle(.secondary)
                Text(dictation.appName ?? "unknown app").font(.caption).bold()
                Text(dictation.modeName).font(.caption).foregroundStyle(.secondary)
                if dictation.contextSent {
                    Label("context sent", systemImage: "paperplane.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(dictation.destination.label)
                    .font(.caption2)
                    .foregroundStyle(dictation.destination == .cloud ? .secondary : .green)
                if dictation.action.isDestructive {
                    Label(dictation.action.label, systemImage: "pencil.and.outline")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Text("via \(dictation.method.rawValue)").font(.caption2).foregroundStyle(.secondary)
            }

            Text(dictation.raw)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if dictation.llmUsed {
                Text(dictation.result)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Text(dictation.timings).font(.caption2).foregroundStyle(.secondary)

            HStack {
                Button("Re-insert") { state.reinsert(dictation) }
                if dictation.canRevert {
                    Button("Revert") { state.revert(dictation) }
                }
                Menu("Re-run as…") {
                    ForEach(state.config.modes, id: \.name) { mode in
                        Button(mode.name) { state.rerun(dictation, as: mode) }
                    }
                }
                .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
