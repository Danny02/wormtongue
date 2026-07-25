import SwiftUI
import VoiceModeCore

struct OverlayView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        .padding(4)
        .animation(.easeOut(duration: 0.18), value: state.phase)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var icon: some View {
        switch state.phase {
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: 15, weight: .semibold))
        case .transcribing:
            Image(systemName: "waveform")
                .foregroundStyle(.primary)
                .font(.system(size: 15, weight: .semibold))
        case let .rewriting(contextSent):
            Image(systemName: contextSent ? "paperplane.fill" : "wand.and.stars")
                .foregroundStyle(contextSent ? .orange : .accentColor)
                .font(.system(size: 15, weight: .semibold))
        case .inserting, .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 15, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15, weight: .semibold))
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state.phase {
        case .recording:
            LevelMeter(level: state.inputLevel)
        case .transcribing, .rewriting, .inserting:
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
        case .done, .failed, .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch state.phase {
        case .idle: return ""
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing"
        case .rewriting:
            switch state.activeIntent {
            case .compose: return "Rewriting"
            case .replaceSelection: return "Replacing selection"
            case .revise: return "Revising draft"
            }
        case .inserting: return "Inserting"
        case .done: return state.revertable != nil ? "Field rewritten" : "Inserted"
        case .failed: return "Dictation failed"
        }
    }

    private var subtitle: String? {
        switch state.phase {
        case .recording:
            let seconds = state.recordedSeconds
            let hint = state.targetAppName.map { "into \($0)" } ?? "hold to keep talking"
            return String(format: "%@ · %.1fs", hint, seconds)
        case .transcribing:
            return "on this Mac"
        case let .rewriting(contextSent):
            // Say out loud what is being changed, and when the window's text is
            // leaving the machine.
            let scope = contextSent ? "sending screen context" : "transcript only"
            return "\(state.activeIntent.label) · \(scope)"
        case .inserting:
            return state.activeModeName
        case .done:
            // A rewrite overwrote something, so say how to get it back.
            if state.revertable != nil {
                return "Revert from the menu bar · \(state.lastResultPreview ?? "")"
            }
            return state.lastResultPreview
        case .failed:
            return state.failureMessage
        case .idle:
            return nil
        }
    }
}

/// Five bars driven by the smoothed input level. Purely so the user can see the
/// mic is actually hearing them — the most common "is this broken?" moment.
private struct LevelMeter: View {
    let level: Float
    private let bars = 5

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
                let threshold = Float(index + 1) / Float(bars)
                let lit = level >= threshold * 0.62
                Capsule()
                    .fill(lit ? Color.red.opacity(0.9) : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: height(for: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let base: CGFloat = 6 + CGFloat(index) * 3
        let reach = CGFloat(max(0, min(1, level)))
        return base * (0.55 + 0.45 * reach)
    }
}
