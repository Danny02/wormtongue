import SwiftUI
import WormtongueCore

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
                if !dictation.llmUsed {
                    Text("raw").font(.caption2).foregroundStyle(.secondary)
                }
                if dictation.action.isDestructive {
                    Label(dictation.action.label, systemImage: "pencil.and.outline")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Text("via \(dictation.method.rawValue)").font(.caption2).foregroundStyle(.secondary)
            }

            labelledBlock("Transcript (Whisper)", dictation.raw)

            if dictation.llmUsed {
                Text(dictation.result)
                    .font(.body)
                    .textSelection(.enabled)
            }

            DetailsSection(dictation: dictation)

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

/// Shared by the row and its details panel.
private func chip(_ name: String, _ value: String) -> some View {
    Text("\(name): \(value)")
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
}

private func labelledBlock(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption2).foregroundStyle(.secondary)
        Text(body)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Everything the rewrite pass saw and produced, collapsed by default. This is the
/// "why did it say that?" panel: without the system prompt and the mode beside the
/// output, a surprising rewrite is unattributable.
///
/// Its own view because each row needs its own expanded state — and it draws the
/// chevron by hand, since `DisclosureGroup` renders without one inside a `List`.
private struct DetailsSection: View {
    let dictation: Dictation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption2)
                    Text(expanded ? "Hide details" : "Details")
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            if expanded { body(for: dictation) }
        }
    }

    @ViewBuilder
    private func body(for dictation: Dictation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if dictation.llmUsed {
                HStack(spacing: 10) {
                    chip("mode", dictation.modeName)
                    if let model = dictation.model { chip("model", model) }
                    chip("intent", dictation.intent.rawValue)
                }
                if let endpoint = dictation.endpoint { chip("endpoint", endpoint) }
                if let system = dictation.systemPrompt {
                    labelledBlock("System prompt", system)
                }
                if let user = dictation.userMessage {
                    labelledBlock("User message", user)
                }
                if let thinking = dictation.thinking {
                    labelledBlock("Thinking", thinking)
                } else {
                    Text("Thinking: none returned by this endpoint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                labelledBlock("Output", dictation.result)
            } else {
                Text(
                    "No rewrite pass ran — this app is in denied_bundle_ids, "
                        + "so the transcript was inserted unchanged and nothing left the Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let previous = dictation.previousFieldValue, !previous.isEmpty {
                labelledBlock("Field before this dictation", previous)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
