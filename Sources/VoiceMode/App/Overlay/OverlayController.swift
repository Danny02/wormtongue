import AppKit
import SwiftUI

/// Owns the floating status panel.
///
/// Every window flag here exists to keep the panel from stealing focus: the whole
/// app is pointless if showing a progress indicator moves the keyboard away from
/// the field we are about to type into. In particular it is shown with
/// `orderFrontRegardless()`, never `makeKeyAndOrderFront`, and the style mask
/// includes `.nonactivatingPanel`.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private let size = CGSize(width: 340, height: 60)
    /// Distance from the bottom of the active screen's visible frame.
    private let bottomInset: CGFloat = 130

    func attach(_ state: AppState) {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Purely informational: clicks must fall through to whatever is underneath.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: OverlayView().environmentObject(state))

        self.panel = panel
    }

    func show() {
        guard let panel else { return }
        hideTask?.cancel()
        hideTask = nil
        reposition(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// `after == 0` hides immediately; otherwise the panel lingers so the user can
    /// read the result before it fades.
    func hide(after seconds: TimeInterval = 0) {
        guard let panel else { return }
        hideTask?.cancel()
        guard seconds > 0 else {
            panel.orderOut(nil)
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
    }

    /// Follows the screen the pointer is on — on a multi-display setup the overlay
    /// belongs where the user is looking, not always on the main display.
    private func reposition(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(
            CGRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + bottomInset,
                width: size.width,
                height: size.height),
            display: false)
    }
}
