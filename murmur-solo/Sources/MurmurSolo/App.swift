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
        controller = DictationController(modelPath: Self.resolveModelPath())
        HUDController.shared.attach(controller)
        HUDController.shared.show()

        buildStatusItem()
        observeState()

        // Don't fire permission prompts at launch — Microphone and Input
        // Monitoring requests pop simultaneously and clobber each other. Instead
        // the user grants each from the menu bar (one at a time), where every
        // permission shows ✓/⚠ and opens its specific Settings pane.
        DebugLog.log("Permissions at launch: mic=\(Permissions.micGranted) " +
                     "inputMonitoring=\(Permissions.inputMonitoringLive) " +
                     "accessibility=\(Permissions.accessibilityLive)")

        Permissions.recordLaunchState()
        controller.onPermissionDenied = { [weak self] in self?.refreshStatusIcon() }
        controller.start()

        // The HUD's right-click menu posts these to open Settings / relaunch.
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .murmurOpenSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restartApp),
                                               name: .murmurRestart, object: nil)

        DebugLog.log("Murmur Solo launched. Trigger: \(Settings.shared.trigger.label). " +
                     "model=\(Self.resolveModelPath())")
    }

    /// Find the bundled GGML model; fall back to a dev-tree Models/ folder.
    static func resolveModelPath() -> String {
        let name = "ggml-large-v3-turbo"
        if let p = Bundle.main.path(forResource: name, ofType: "bin") { return p }
        let fm = FileManager.default
        let candidates = [
            "\(fm.currentDirectoryPath)/Models/\(name).bin",
            "Models/\(name).bin",
        ]
        for c in candidates where fm.fileExists(atPath: c) { return c }
        return Bundle.main.bundlePath + "/Contents/Resources/\(name).bin"
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
        setButtonImage(button, symbol: ok ? "waveform.circle.fill" : "waveform.circle")
    }

    private func setButtonImage(_ button: NSStatusBarButton, symbol: String) {
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur Solo") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "S"
        }
    }

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

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        // At-a-glance setup alert at the very top.
        let unconfigured = Permissions.unconfigured
        if !unconfigured.isEmpty {
            let warn = NSMenuItem(title: "⚠ Setup needed — enable: " + unconfigured.joined(separator: ", "),
                                  action: #selector(openPrivacySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            let warnHint = NSMenuItem(title: "    (click a permission below to enable it)", action: nil, keyEquivalent: "")
            warnHint.isEnabled = false
            menu.addItem(warnHint)
            menu.addItem(.separator())
        } else if Permissions.needsRestart {
            let r = NSMenuItem(title: "↻ Permission granted — Restart to apply",
                               action: #selector(restartApp), keyEquivalent: "")
            r.target = self
            menu.addItem(r)
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: s.trigger.label + " to dictate", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "Double-tap to lock hands-free", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        // On-device model status.
        let modelRow = NSMenuItem(
            title: controller.modelReady ? "✓ On-device model loaded" : "◌ Loading model…",
            action: nil, keyEquivalent: "")
        modelRow.isEnabled = false
        menu.addItem(modelRow)

        let permHeader = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permHeader.isEnabled = false
        menu.addItem(permHeader)
        for p in Permissions.Perm.allCases {
            let item = NSMenuItem(title: Permissions.menuLabel(p), action: #selector(fixPermission(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let sound = NSMenuItem(title: "Sound feedback", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = s.soundFeedback ? .on : .off
        menu.addItem(sound)

        // Language submenu.
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (code, name) in Settings.languages {
            let mi = NSMenuItem(title: name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = code
            mi.state = (code == s.language) ? .on : .off
            langMenu.addItem(mi)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

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
        let restart = NSMenuItem(title: Permissions.needsRestart ? "↻ Restart to apply changes" : "Restart Murmur Solo",
                                 action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        let quit = NSMenuItem(title: "Quit Murmur Solo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleSound() { Settings.shared.soundFeedback.toggle() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { Settings.shared.language = code }
    }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t = Settings.Trigger(rawValue: raw) else { return }
        Settings.shared.trigger = t
        Permissions.triggerChanged = true   // hotkey binds at launch; needs relaunch
    }

    @objc private func fixPermission(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Permissions.Perm { Permissions.fix(p) }
    }

    @objc private func openPrivacySettings() { Permissions.openFirstUnconfigured() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Murmur Solo Settings"
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Relaunch a fresh instance, then quit this one — the way to make a newly
    /// granted Input Monitoring / Accessibility permission take effect.
    @objc private func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
