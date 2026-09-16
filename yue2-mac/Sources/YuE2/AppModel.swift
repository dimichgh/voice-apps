import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum Pane: String, Hashable, CaseIterable, Identifiable {
    case create, cover, library
    var id: Self { self }

    var title: String {
        switch self {
        case .create: "Create"
        case .cover: "Cover"
        case .library: "Library"
        }
    }
    var symbol: String {
        switch self {
        case .create: "music.note"
        case .cover: "music.mic"
        case .library: "square.grid.2x2"
        }
    }
}

/// Window-level state: the selected pane, what the inspector shows, and the one place menu commands route through.
@MainActor
final class AppModel: ObservableObject {
    @Published var pane: Pane = .create
    @Published var showInspector = true
    @Published var librarySelection: Song.ID?
    @Published private(set) var createSong: Song?
    @Published private(set) var coverSong: Song?
    /// Bumped on every finished generation; drives the Library icon bounce.
    @Published private(set) var completions = 0

    let server = ServerLauncher()
    let create = CreateModel()
    let cover = CoverModel()
    let library = LibraryStore()
    let player = PlayerModel()

    private var forwarding: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    init() {
        // Toolbar, menus and inspector depend on job/server state; the form models (typing) are deliberately not forwarded.
        for publisher in [server.objectWillChange, create.job.objectWillChange, cover.job.objectWillChange,
                          cover.transcribeJob.objectWillChange, library.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &forwarding)
        }
        create.job.onResult = { [weak self] r in self?.finished(r, pane: .create) }
        cover.job.onResult = { [weak self] r in self?.finished(r, pane: .cover) }
        library.reload()

        // Space plays/pauses like Music, unless a text view has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }
    }

    // MARK: Derived state

    var inspectorSong: Song? {
        switch pane {
        case .create: createSong
        case .cover: coverSong
        case .library: library.song(id: librarySelection)
        }
    }

    var activeJob: SongJob? {
        switch pane {
        case .create: create.job
        case .cover: cover.job
        case .library: nil
        }
    }

    var serverReady: Bool {
        if case .ready = server.state { return true }
        return false
    }

    var isRunning: Bool { activeJob?.isRunning ?? false }

    var canGenerate: Bool {
        guard serverReady, let job = activeJob, !job.isRunning else { return false }
        return pane != .cover || !cover.transcribeJob.isRunning
    }

    var generateTitle: String { pane == .cover ? "Generate Cover" : "Generate Song" }

    // MARK: Actions

    func generate() {
        guard canGenerate else { return }
        showInspector = true
        switch pane {
        case .create: Task { await create.generate() }
        case .cover: Task { await cover.generate() }
        case .library: break
        }
    }

    func cancel() { activeJob?.cancel() }

    @discardableResult
    func playPause() -> Bool {
        if player.isPlaying { player.toggle(); return true }
        if let song = inspectorSong { player.toggle(song); return true }
        if player.songID != nil { player.toggle(); return true }
        return false
    }

    func remix(_ song: Song) {
        create.apply(song)
        pane = .create
    }

    func makeCover(of song: Song) {
        cover.source = song.flac ?? song.mp3
        pane = .cover
    }

    func reveal(_ song: Song) {
        NSWorkspace.shared.activateFileViewerSelecting([song.flac ?? song.mp3 ?? song.folder])
    }

    func save(_ song: Song, type: String) {
        guard let source = type == "flac" ? song.flac : song.mp3 else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(song.title).\(type)"
        panel.allowedContentTypes = [UTType(filenameExtension: type) ?? .audio]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    func trash(_ song: Song) {
        if player.songID == song.id { player.stop() }
        if librarySelection == song.id { librarySelection = nil }
        if createSong == song { createSong = nil }
        if coverSong == song { coverSong = nil }
        withAnimation(.smooth) { library.trash(song) }
    }

    private func finished(_ result: JobResult, pane: Pane) {
        guard let path = result.flac ?? result.mp3 else { return }
        let song = Song(folder: URL(fileURLWithPath: path).deletingLastPathComponent())
        withAnimation(.smooth) { library.reload() }
        if pane == .create { createSong = song } else { coverSong = song }
        completions += 1
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49,   // space
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
              let window = event.window, window === NSApp.mainWindow,
              !(window.firstResponder is NSText)
        else { return event }
        return playPause() ? nil : event
    }
}
