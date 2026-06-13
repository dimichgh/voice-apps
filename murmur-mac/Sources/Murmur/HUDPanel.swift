import AppKit
import SwiftUI

/// Owns the floating overlay. The critical constraint: this window must NEVER
/// take key/main status, or focus leaves the app you're dictating into and the
/// paste lands nowhere. A borderless `.nonactivatingPanel` that refuses to
/// become key, floating above normal windows and visible on every Space, is the
/// configuration that satisfies that.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private var panel: NonActivatingPanel?
    private weak var controller: DictationController?

    func attach(_ controller: DictationController) {
        self.controller = controller
    }

    /// Make the HUD visible and bring it to the active screen. Called at launch
    /// (it then stays up, breathing in its idle state) and again when dictation
    /// begins so it follows the cursor's screen.
    func show() {
        let panel = ensurePanel()
        reposition(panel)
        panel.orderFrontRegardless()
    }

    /// The HUD is persistent and flowing, so there's nothing to hide — once a
    /// turn ends the controller sets phase back to `.idle` and the view returns
    /// to its calm breathing animation on its own. Kept as a no-op so callers
    /// reading as "this turn is done" stay readable.
    func hide() {}

    private func ensurePanel() -> NonActivatingPanel {
        if let panel { return panel }
        // Wide enough for the listening state; the pill inside sizes itself per
        // state and the surrounding panel area is transparent + click-through.
        let size = NSSize(width: 260, height: 48)
        let p = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents = true           // purely a readout; never grabs clicks
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        if let controller {
            let host = NSHostingView(rootView: HUDView(controller: controller))
            host.frame = NSRect(origin: .zero, size: size)
            p.contentView = host
        }
        panel = p
        return p
    }

    /// Bottom-center of whichever screen has the cursor, a little above the Dock.
    private func reposition(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// An NSPanel that will not become key or main — the whole point.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
