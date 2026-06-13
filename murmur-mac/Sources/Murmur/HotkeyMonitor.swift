import Foundation
import CoreGraphics
import AppKit

/// Watches a single side-modifier key globally and reports press / release.
///
/// We use a CGEventTap (not an NSEvent global monitor) for three reasons:
///   1. It reliably sees `flagsChanged` for left-vs-right modifiers and fn.
///   2. It runs even while another app is frontmost (we're an agent app).
///   3. macOS hands us the keycode so we can target the RIGHT-side modifier
///      specifically, leaving the left one free for normal use.
///
/// Operational gotchas handled here (these silently kill naive taps):
///   - The tap must be serviced by a thread with a live CFRunLoop.
///   - macOS disables the tap if a callback runs long or on certain user input;
///     we re-enable it on `tapDisabledByTimeout` / `tapDisabledByUserInput`.
///   - A "listenOnly" tap can't be created without Accessibility / Input
///     Monitoring permission — `CGEvent.tapCreate` returns nil; we surface that.
final class HotkeyMonitor {
    enum Edge { case down, up }

    /// Delivered on the main queue.
    var onEvent: ((Edge) -> Void)?
    /// Called once if the tap can't be created (missing permission).
    var onPermissionDenied: (() -> Void)?

    private var trigger: Settings.Trigger
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var tapRunLoop: CFRunLoop?     // the tap thread's run loop, for teardown
    private var isDown = false

    init(trigger: Settings.Trigger) {
        self.trigger = trigger
    }

    func updateTrigger(_ t: Settings.Trigger) {
        trigger = t
        isDown = false
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "com.local.murmur.hotkey"
        t.start()
        thread = t
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        // Tear down on the tap's OWN run loop (not the caller's), then stop it
        // so the thread exits cleanly.
        if let rl = tapRunLoop {
            if let src = runLoopSource {
                CFRunLoopRemoveSource(rl, src, .commonModes)
            }
            CFRunLoopStop(rl)
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        thread = nil
    }

    // MARK: - Tap thread

    private func runLoop() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // we observe; we never swallow the key
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            DebugLog.log("HotkeyMonitor: tapCreate failed — Accessibility/Input Monitoring not granted")
            DispatchQueue.main.async { [weak self] in self?.onPermissionDenied?() }
            return
        }
        self.tap = tap

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        tapRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.log("HotkeyMonitor: tap installed, watching \(trigger.rawValue)")
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DebugLog.log("HotkeyMonitor: tap re-enabled after \(type.rawValue)")
            return
        }
        guard type == .flagsChanged else { return }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == trigger.keycode else { return }

        // The modifier's device-dependent flag bit tells us down vs up:
        // present in the new flag set → key went down; absent → key went up.
        let down = event.flags.rawValue & trigger.flagMask != 0
        guard down != isDown else { return }
        isDown = down
        let edge: Edge = down ? .down : .up
        DispatchQueue.main.async { [weak self] in self?.onEvent?(edge) }
    }
}

private extension Settings.Trigger {
    /// Hardware keycode for the targeted (right-side) modifier.
    var keycode: Int64 {
        switch self {
        case .rightOption:  return 61   // kVK_RightOption
        case .rightCommand: return 54   // kVK_RightCommand
        case .fn:           return 63   // kVK_Function
        }
    }

    /// Device-dependent CGEventFlags bit set while this key is held.
    /// (NX_DEVICER*KEYMASK constants; fn uses the secondary-fn mask.)
    var flagMask: UInt64 {
        switch self {
        case .rightOption:  return 0x000040   // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x000010   // NX_DEVICERCMDKEYMASK
        case .fn:           return 0x800000   // kCGEventFlagMaskSecondaryFn
        }
    }
}
