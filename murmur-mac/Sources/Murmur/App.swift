import AppKit
import SwiftUI
import AVFoundation
import Combine

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no Dock icon, no app menu. Murmur lives in the status bar
        // and floats a non-activating HUD, so it never steals focus.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: DictationController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DictationController()
        HUDController.shared.attach(controller)
        HUDController.shared.show()      // persistent flowing indicator, idle from launch

        buildStatusItem()
        observeState()

        // Ask for mic up front so the first dictation isn't eaten by a prompt.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DebugLog.log("Microphone access granted=\(granted)")
        }
        // The CGEventTap can be "installed" yet receive ZERO events without
        // Input Monitoring — tapCreate succeeds regardless. Prompt for it
        // explicitly so the hotkey actually fires.
        let listen = CGRequestListenEventAccess()
        DebugLog.log("Input Monitoring access=\(listen)")

        controller.onPermissionDenied = { [weak self] in
            self?.refreshStatusIcon()
        }
        controller.start()

        DebugLog.log("Murmur launched. Trigger: \(Settings.shared.trigger.label). " +
                     "Accessibility trusted=\(AXIsProcessTrusted())")
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let ok = AXIsProcessTrusted()
        let name = ok ? "mic.fill" : "mic.slash.fill"
        setButtonImage(button, symbol: name)
    }

    /// Set the symbol, falling back to a text title if the symbol can't load —
    /// an image-only `variableLength` status item with a nil image renders
    /// zero-width and invisible, which looks like "the icon never appeared".
    private func setButtonImage(_ button: NSStatusBarButton, symbol: String) {
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "🎙"
        }
    }

    /// Recolor / re-glyph the menu-bar icon while listening so the bar itself
    /// is a status indicator.
    private func observeState() {
        controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let button = self?.statusItem?.button else { return }
                switch phase {
                case .listening:
                    self?.setButtonImage(button, symbol: "waveform")
                case .transcribing, .inserting:
                    self?.setButtonImage(button, symbol: "waveform.badge.magnifyingglass")
                default:
                    self?.refreshStatusIcon()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu (rebuilt each open so checkmarks/status are live)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        let header = NSMenuItem(title: s.trigger.label + " to dictate", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "Double-tap to lock hands-free", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        // Permission status (read-only indicators + fix buttons). All three are
        // required: mic to hear, Input Monitoring so the hotkey fires at all,
        // Accessibility to post the paste keystroke.
        addPermissionRow(menu, label: "Microphone", granted: micGranted(),
                         action: nil)
        addPermissionRow(menu, label: "Input Monitoring (hotkey)", granted: CGPreflightListenEventAccess(),
                         action: #selector(openInputMonitoring))
        addPermissionRow(menu, label: "Accessibility (typing)", granted: AXIsProcessTrusted(),
                         action: #selector(openAccessibility))
        menu.addItem(.separator())

        let cleanup = NSMenuItem(title: "Clean up with local model",
                                 action: #selector(toggleCleanup), keyEquivalent: "")
        cleanup.target = self
        cleanup.state = s.cleanupEnabled ? .on : .off
        menu.addItem(cleanup)

        let sound = NSMenuItem(title: "Sound feedback",
                               action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = s.soundFeedback ? .on : .off
        menu.addItem(sound)

        // Trigger submenu.
        let triggerItem = NSMenuItem(title: "Activation key", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in Settings.Trigger.allCases {
            let mi = NSMenuItem(title: t.label, action: #selector(selectTrigger(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t.rawValue
            mi.state = (t == s.trigger) ? .on : .off
            sub.addItem(mi)
        }
        triggerItem.submenu = sub
        menu.addItem(triggerItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addPermissionRow(_ menu: NSMenu, label: String, granted: Bool, action: Selector?) {
        let title = (granted ? "✓ " : "⚠ ") + label + (granted ? "" : " — not granted")
        let item = NSMenuItem(title: title, action: granted ? nil : action, keyEquivalent: "")
        item.target = granted ? nil : self
        item.isEnabled = !granted && action != nil
        menu.addItem(item)
    }

    private func micGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Actions

    @objc private func toggleCleanup() { Settings.shared.cleanupEnabled.toggle() }
    @objc private func toggleSound() { Settings.shared.soundFeedback.toggle() }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t = Settings.Trigger(rawValue: raw) else { return }
        Settings.shared.trigger = t
        controller.updateTrigger(t)
    }

    @objc private func openAccessibility() {
        TextInjector.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoring() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            win.title = "Murmur Settings"
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
