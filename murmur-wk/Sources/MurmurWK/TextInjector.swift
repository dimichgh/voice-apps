import Foundation
import AppKit
import CoreGraphics

/// Inserts transcribed text into whatever app currently has keyboard focus.
///
/// Strategy: clipboard paste. We stash the current pasteboard, put our text on
/// it, synthesize ⌘V, then restore the pasteboard a beat later. This is what
/// production dictation apps do — it's the only method that works uniformly
/// across native, Electron, terminal, and web text fields. (Synthesizing the
/// text as unicode keystrokes is unreliable past ~20 chars and breaks in
/// several app classes.)
///
/// Requires Accessibility permission (to post the ⌘V keystroke). Restoring the
/// pasteboard is deliberately delayed: paste is asynchronous, and restoring too
/// soon makes the target read the OLD clipboard contents.
enum TextInjector {

    /// True if we're allowed to post synthetic keystrokes. Posting silently
    /// no-ops without Accessibility, so the controller checks this first.
    static var canInject: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility (opens the System Settings pane).
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general

        // Snapshot the entire pasteboard so we can restore arbitrary content
        // (not just strings — images, files, RTF the user had copied).
        let saved: [(NSPasteboard.PasteboardType, Data)] = pb.pasteboardItems?.first.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Give the pasteboard write a moment to land, then ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            pressCommandV()
            // Restore the user's clipboard after the paste has been consumed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pb.clearContents()
                if saved.isEmpty {
                    return
                }
                let item = NSPasteboardItem()
                for (type, data) in saved {
                    item.setData(data, forType: type)
                }
                pb.writeObjects([item])
            }
        }
        DebugLog.log("TextInjector: pasted \(text.count) chars")
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else {
            DebugLog.log("TextInjector: failed to create CGEvent for ⌘V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
