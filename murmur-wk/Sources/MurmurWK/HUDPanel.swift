import AppKit
import SwiftUI

/// Owns the floating overlay. The critical constraint: this window must NEVER
/// take key/main status, or focus leaves the app you're dictating into and the
/// paste lands nowhere. A borderless `.nonactivatingPanel` that refuses to
/// become key, floating above normal windows and visible on every Space.
///
/// The pill is draggable (isMovableByWindowBackground) and its position is
/// remembered across launches; right-clicking it opens a Quit/Settings menu.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private var panel: NonActivatingPanel?
    private weak var controller: DictationController?

    private let originXKey = "hudOriginX"
    private let originYKey = "hudOriginY"

    func attach(_ controller: DictationController) {
        self.controller = controller
    }

    func show() {
        let panel = ensurePanel()
        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    /// The HUD is persistent and flowing, so there's nothing to hide — once a
    /// turn ends the controller sets phase back to `.idle` and the view returns
    /// to its calm breathing animation on its own.
    func hide() {}

    private func ensurePanel() -> NonActivatingPanel {
        if let panel { return panel }
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
        p.hasShadow = false                    // glass shadow is drawn in SwiftUI
        p.isMovableByWindowBackground = true   // drag the pill anywhere to move it
        p.ignoresMouseEvents = false           // needed for drag + right-click menu
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        if let controller {
            let host = NSHostingView(rootView: HUDView(controller: controller))
            host.frame = NSRect(origin: .zero, size: size)
            p.contentView = host
        }
        // Persist the position whenever the user drags the pill. Reads the
        // origin straight from the moved window, so there's no actor-isolation
        // tangle with `self`.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [originXKey, originYKey] note in
            guard let win = note.object as? NSWindow else { return }
            let o = win.frame.origin
            UserDefaults.standard.set(Double(o.x), forKey: originXKey)
            UserDefaults.standard.set(Double(o.y), forKey: originYKey)
        }
        panel = p
        return p
    }

    /// Restore the user's saved position if it's still on a connected screen;
    /// otherwise default to bottom-center of the screen under the cursor.
    private func positionPanel(_ panel: NSPanel) {
        let d = UserDefaults.standard
        if d.object(forKey: originXKey) != nil, d.object(forKey: originYKey) != nil {
            let origin = NSPoint(x: d.double(forKey: originXKey), y: d.double(forKey: originYKey))
            if NSScreen.screens.contains(where: {
                $0.visibleFrame.intersects(NSRect(origin: origin, size: panel.frame.size))
            }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 120))
    }
}

/// An NSPanel that will not become key or main — the whole point.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    /// Posted by the HUD's right-click menu; the AppDelegate opens Settings.
    static let murmurOpenSettings = Notification.Name("MurmurOpenSettings")
    /// Posted by the HUD's right-click menu; the AppDelegate relaunches the app.
    static let murmurRestart = Notification.Name("MurmurRestart")
}
