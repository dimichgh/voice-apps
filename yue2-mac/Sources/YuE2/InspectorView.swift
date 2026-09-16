import SwiftUI
import AVFoundation
import AppKit

// MARK: - Player

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var songID: Song.ID?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    @discardableResult
    func load(_ song: Song) -> Bool {
        guard let url = song.audioURL, let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        stop()
        player = p
        p.prepareToPlay()
        songID = song.id
        duration = p.duration
        return true
    }

    /// Plays/pauses `song`, switching to it first if another song is loaded.
    func toggle(_ song: Song) {
        if songID != song.id { guard load(song) else { return } }
        toggle()
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    func seek(_ song: Song, to fraction: Double) {
        if songID != song.id { guard load(song) else { return } }
        let t = fraction * duration
        player?.currentTime = t
        currentTime = t
    }

    func skip(_ delta: Double) {
        guard let player else { return }
        let t = min(max(player.currentTime + delta, 0), duration)
        player.currentTime = t
        currentTime = t
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        isPlaying = false
        songID = nil
        currentTime = 0
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
        }
    }
}

// MARK: - Waveform

enum Waveform {
    @MainActor private static var cache: [Song.ID: [Float]] = [:]

    @MainActor
    static func levels(for song: Song, bins: Int = 110) async -> [Float] {
        if let cached = cache[song.id] { return cached }
        guard let url = song.flac ?? song.mp3 else { return [] }
        let levels = await Task.detached(priority: .utility) { compute(url, bins: bins) }.value
        cache[song.id] = levels
        return levels
    }

    /// Subsampled RMS per bin, normalised to the loudest bin.
    nonisolated static func compute(_ url: URL, bins: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let format = file.processingFormat
        let perBin = AVAudioFrameCount(max(1, file.length / AVAudioFramePosition(bins)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: perBin) else { return [] }
        let stride = max(1, Int(perBin) / 512)
        var out: [Float] = []
        for _ in 0..<bins {
            do { try file.read(into: buffer, frameCount: perBin) } catch { break }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            var sum: Float = 0
            var count = 0
            for c in 0..<Int(format.channelCount) {
                var i = 0
                while i < Int(buffer.frameLength) {
                    sum += data[c][i] * data[c][i]
                    count += 1
                    i += stride
                }
            }
            out.append((sum / Float(max(count, 1))).squareRoot())
        }
        let peak = out.max() ?? 0
        return peak > 0 ? out.map { pow($0 / peak, 0.8) } : out
    }
}

/// Bars for the whole song; played bars take the accent colour. Click or drag to seek.
struct WaveformView: View {
    let song: Song
    let progress: Double
    let onSeek: (Double) -> Void
    @State private var levels: [Float] = []

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = levels.isEmpty ? 110 : levels.count
                let slot = size.width / CGFloat(n)
                for i in 0..<n {
                    let level = levels.isEmpty ? 0.06 : CGFloat(levels[i])
                    let h = max(3, level * size.height)
                    let rect = CGRect(x: CGFloat(i) * slot + slot * 0.18, y: (size.height - h) / 2,
                                      width: slot * 0.64, height: h)
                    let played = (CGFloat(i) + 0.5) / CGFloat(n) <= progress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: slot * 0.32),
                             with: .color(played ? brandAccent : Color.secondary.opacity(0.32)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(min(max(value.location.x / max(geo.size.width, 1), 0), 1))
            })
        }
        .task(id: song.id) {
            levels = await Waveform.levels(for: song)
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            onSeek(min(max(progress + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }
}

// MARK: - Inspector

struct InspectorHost: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        switch app.pane {
        case .create:
            InspectorView(job: app.create.job, song: app.createSong, isCover: false,
                          artSeed: app.create.seed, artStyle: app.create.style)
        case .cover:
            InspectorView(job: app.cover.job, song: app.coverSong, isCover: true,
                          artSeed: app.cover.seed, artStyle: app.cover.style)
        case .library:
            InspectorView(job: nil, song: app.inspectorSong, isCover: false, artSeed: 0, artStyle: "")
        }
    }
}

struct InspectorView: View {
    let job: SongJob?
    let song: Song?
    let isCover: Bool
    let artSeed: Int
    let artStyle: String
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let job, job.isRunning {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SongArt(seed: artSeed, style: artStyle, symbol: isCover ? "music.mic" : "music.note", animating: true)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                    PhaseTimeline(job: job, isCover: isCover)
                }
                .padding(16)
            }
        } else if let song {
            SongInspector(song: song, error: job?.errorMessage, player: app.player)
                .id(song.id)
        } else if let error = job?.errorMessage {
            ContentUnavailableView {
                Label("Generation Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            }
        } else {
            switch app.pane {
            case .create:
                ContentUnavailableView("No Song Yet", systemImage: "music.note",
                                       description: Text("Describe a style and add lyrics, then choose Generate Song (⌘↩)."))
            case .cover:
                ContentUnavailableView("No Cover Yet", systemImage: "music.mic",
                                       description: Text("Add a source song and transcribe it, then choose Generate Cover (⌘↩)."))
            case .library:
                ContentUnavailableView("Select a Song", systemImage: "square.grid.2x2",
                                       description: Text("Choose a song to play it and see how it was made."))
            }
        }
    }
}

struct SongInspector: View {
    let song: Song
    var error: String?
    @ObservedObject var player: PlayerModel
    @EnvironmentObject var app: AppModel
    @State private var showLyrics = false
    @State private var showScore = false
    @State private var confirmTrash = false

    private var isCurrent: Bool { player.songID == song.id }
    private var progress: Double { isCurrent && player.duration > 0 ? player.currentTime / player.duration : 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.title2.bold()).lineLimit(2)
                    if !song.subtitle.isEmpty {
                        Text(song.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                scrubber
                actions
                details
                if !song.lyrics.isEmpty, song.lyrics.lowercased() != "[instrumental]" {
                    DisclosureGroup(song.instrumental ? "Section Plan" : "Lyrics", isExpanded: $showLyrics) {
                        Text(song.lyrics)
                            .font(song.instrumental ? .system(.callout, design: .monospaced) : .callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                if !song.abc.isEmpty {
                    DisclosureGroup("Score (ABC)", isExpanded: $showScore) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(song.abc)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Copy Score") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(song.abc, forType: .string)
                                }
                                Button("Use in Cover") {
                                    app.cover.abc = song.abc
                                    app.pane = .cover
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .padding(16)
        }
        .confirmationDialog("Move “\(song.title)” to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { app.trash(song) }
        } message: {
            Text("The song folder, including the FLAC, MP3 and score, moves to the Trash.")
        }
    }

    private var artwork: some View {
        SongArt(seed: song.seed ?? 0, style: song.style, symbol: song.symbol)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background {
                // Soft glow of the artwork's own colours behind it.
                SongArt(seed: song.seed ?? 0, style: song.style)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .blur(radius: 28)
                    .opacity(0.55)
                    .offset(y: 10)
            }
            .overlay(alignment: .bottom) {
                TransportPill(song: song, player: player)
                    .padding(.bottom, 14)
            }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            WaveformView(song: song, progress: progress) { player.seek(song, to: $0) }
                .frame(height: 44)
            HStack {
                Text(timecode(isCurrent ? player.currentTime : 0))
                Spacer()
                Text(timecode(isCurrent ? player.duration : song.duration ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Save FLAC (Lossless)…") { app.save(song, type: "flac") }.disabled(song.flac == nil)
                Button("Save MP3…") { app.save(song, type: "mp3") }.disabled(song.mp3 == nil)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .fixedSize()
            Button { app.reveal(song) } label: {
                Label("Show in Finder", systemImage: "folder").labelStyle(.iconOnly)
            }
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
            Spacer(minLength: 0)
            Menu {
                Button("Remix in Create", systemImage: "slider.horizontal.3") { app.remix(song) }
                Button("Make a Cover", systemImage: "music.mic") { app.makeCover(of: song) }
                Divider()
                Button("Move to Trash…", systemImage: "trash", role: .destructive) { confirmTrash = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .buttonStyle(.bordered)
    }

    private var details: some View {
        VStack(spacing: 8) {
            LabeledContent("Kind", value: song.kindLabel)
            if let d = song.duration {
                LabeledContent("Length", value: timecode(d))
            }
            if let r = song.renderSeconds {
                if let d = song.duration, r > 0 {
                    LabeledContent("Rendered in", value: "\(timecode(r)) · \(String(format: "%.1f", d / r))× real time")
                } else {
                    LabeledContent("Rendered in", value: timecode(r))
                }
            }
            if let steps = song.steps {
                LabeledContent("Quality", value: QualityPicker.name(steps))
            }
            if let cot = song.planning, let mode = PlanningMode(rawValue: cot) {
                LabeledContent("Score planning", value: mode.label)
            }
            if let seed = song.seed {
                LabeledContent("Seed") { Text(String(seed)).textSelection(.enabled) }
            }
            LabeledContent("Created", value: song.date.formatted(date: .abbreviated, time: .shortened))
            if song.truncated {
                Label("Stopped at the 6-minute limit", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The app's one custom Liquid Glass element: transport controls floating over the artwork.
struct TransportPill: View {
    let song: Song
    @ObservedObject var player: PlayerModel

    var body: some View {
        let current = player.songID == song.id
        let playing = current && player.isPlaying
        GlassEffectContainer {
            HStack(spacing: 22) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .disabled(!current)
                    .accessibilityLabel("Back 15 seconds")
                Button { player.toggle(song) } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel(playing ? "Pause" : "Play")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .disabled(!current)
                    .accessibilityLabel("Forward 15 seconds")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
