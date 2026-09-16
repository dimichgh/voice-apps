import SwiftUI
import AppKit

/// The single brand colour: Generate, playhead, selection and active progress only.
let brandAccent = Color(red: 0.90, green: 0.24, blue: 0.55)

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Single-window utility: closing the window quits, which also stops the server this app started.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct YuE2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("YuE2", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.server)
                .tint(brandAccent)
                .frame(minWidth: 960, minHeight: 620)
                .task { await app.server.ensureRunning() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            SidebarCommands()
            InspectorCommands()
            SongCommands(app: app, player: app.player)
        }
    }
}

struct SongCommands: Commands {
    @ObservedObject var app: AppModel
    @ObservedObject var player: PlayerModel

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Create") { app.pane = .create }.keyboardShortcut("1", modifiers: .command)
            Button("Cover") { app.pane = .cover }.keyboardShortcut("2", modifiers: .command)
            Button("Library") { app.pane = .library }.keyboardShortcut("3", modifiers: .command)
            Divider()
        }
        CommandMenu("Song") {
            Button(app.generateTitle) { app.generate() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!app.canGenerate)
            Button("Cancel Generation") { app.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.isRunning)
            Divider()
            Button(player.isPlaying ? "Pause" : "Play") { app.playPause() }
                .disabled(app.inspectorSong == nil && player.songID == nil)
            Divider()
            Button("Save FLAC…") { if let s = app.inspectorSong { app.save(s, type: "flac") } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(app.inspectorSong?.flac == nil)
            Button("Save MP3…") { if let s = app.inspectorSong { app.save(s, type: "mp3") } }
                .disabled(app.inspectorSong?.mp3 == nil)
            Button("Show in Finder") { if let s = app.inspectorSong { app.reveal(s) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.inspectorSong == nil)
        }
    }
}
