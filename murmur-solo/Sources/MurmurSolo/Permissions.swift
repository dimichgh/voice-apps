import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices

/// Central place for the three permissions Murmur needs, their *effective*
/// status, and the actions to grant them. Used by both the menu-bar menu and
/// the HUD's right-click menu so the flow is identical wherever reached.
///
/// Input Monitoring (the event tap) and Accessibility (the trust check) are
/// bound when the process starts — a grant made while running doesn't take
/// effect until relaunch. So a permission has THREE states, not two:
///   granted        — effective now
///   pendingRestart — granted in Settings this run, but needs a relaunch
///   notGranted     — not set up
enum Permissions {
    enum Perm: CaseIterable {
        case microphone, inputMonitoring, accessibility
        var label: String {
            switch self {
            case .microphone:     return "Microphone"
            case .inputMonitoring: return "Input Monitoring"
            case .accessibility:  return "Accessibility"
            }
        }
    }
    enum Status { case granted, pendingRestart, notGranted }

    // Live TCC reads.
    static var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var inputMonitoringLive: Bool { CGPreflightListenEventAccess() }
    static var accessibilityLive: Bool { AXIsProcessTrusted() }

    // Permissions the user clicked to enable THIS run. Input Monitoring (the
    // event tap) and Accessibility (the trust check) bind at process start, so a
    // grant made this run needs a relaunch to take effect. We detect "this run"
    // via clicks — reliable because the set is empty in a fresh process after a
    // restart — instead of a launch-time TCC snapshot, which can read stale-false
    // and leave the app stuck thinking a restart is pending forever.
    private static var clicked = Set<Perm>()

    /// Set true when the activation key is changed at runtime. The hotkey tap
    /// binds its target key per session, so a new key only takes effect after a
    /// relaunch — same "restart to apply" story as Input Monitoring/Accessibility.
    /// A fresh process starts false, so the prompt clears automatically on restart.
    static var triggerChanged = false

    /// Kept for source compatibility; the model no longer needs a launch snapshot.
    static func recordLaunchState() {}

    static func status(_ p: Perm) -> Status {
        switch p {
        case .microphone:
            return micGranted ? .granted : .notGranted        // updates live, no restart
        case .inputMonitoring:
            if !inputMonitoringLive { return .notGranted }
            return clicked.contains(p) ? .pendingRestart : .granted
        case .accessibility:
            if accessibilityLive { return .granted }
            return clicked.contains(p) ? .pendingRestart : .notGranted
        }
    }

    static var allReady: Bool { Perm.allCases.allSatisfy { status($0) == .granted } }
    static var hasUnconfigured: Bool { Perm.allCases.contains { status($0) == .notGranted } }
    static var needsRestart: Bool {
        triggerChanged || Perm.allCases.contains { status($0) == .pendingRestart }
    }

    /// Names of the permissions still needing initial setup (not pending).
    static var unconfigured: [String] {
        Perm.allCases.filter { status($0) == .notGranted }.map(\.label)
    }

    /// Menu label with a status glyph: ✓ granted, ↻ pending restart, ⚠ missing.
    static func menuLabel(_ p: Perm) -> String {
        switch status(p) {
        case .granted:        return "✓ \(p.label)"
        case .pendingRestart: return "↻ \(p.label) — restart to apply"
        case .notGranted:     return "⚠ \(p.label) — enable…"
        }
    }

    // MARK: - Actions (each user-initiated, so prompts never collide)

    static func fix(_ p: Perm) {
        clicked.insert(p)
        switch p {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openPane("Privacy_Microphone")
            }
        case .inputMonitoring:
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            openPane("Privacy_ListenEvent")
        case .accessibility:
            if !AXIsProcessTrusted() {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            }
            openPane("Privacy_Accessibility")
        }
    }

    static func openFirstUnconfigured() {
        if let p = Perm.allCases.first(where: { status($0) == .notGranted }) { fix(p) }
    }

    static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
