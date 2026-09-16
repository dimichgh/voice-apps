import Foundation
import AVFoundation

/// One finished generation: a folder written by server.py (`<yyyyMMdd-HHmmss>-<song|cover>-<seed>/`).
struct Song: Identifiable, Hashable {
    enum Kind { case song, cover }

    let id: String            // folder name
    let folder: URL
    let kind: Kind
    let date: Date
    let seed: Int?
    let style: String
    let lyrics: String
    let abc: String
    let duration: Double?
    let renderSeconds: Double?
    let steps: Int?
    let planning: String?     // cot: full | melody | off
    let instrumental: Bool
    let truncated: Bool
    let flac: URL?
    let mp3: URL?

    static func == (a: Song, b: Song) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var audioURL: URL? { mp3 ?? flac }
    var title: String { Self.headline(style) }
    var subtitle: String {
        style.split(separator: ",").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ", ")
    }
    var kindLabel: String { kind == .cover ? "Cover" : instrumental ? "Instrumental" : "Song" }
    var symbol: String { kind == .cover ? "music.mic" : instrumental ? "pianokeys" : "music.note" }

    /// First clause of a style prompt, used as a title ("Lo-fi hip hop, dusty drums" → "Lo-fi hip hop").
    static func headline(_ style: String) -> String {
        let first = style.split(separator: ",", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else { return "Untitled" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    init?(folder: URL) {
        let fm = FileManager.default
        let flacURL = folder.appendingPathComponent("song.flac")
        let mp3URL = folder.appendingPathComponent("song.mp3")
        flac = fm.fileExists(atPath: flacURL.path) ? flacURL : nil
        mp3 = fm.fileExists(atPath: mp3URL.path) ? mp3URL : nil
        guard flac != nil || mp3 != nil else { return nil }

        self.folder = folder
        id = folder.lastPathComponent
        let parts = id.split(separator: "-")
        if parts.count >= 4, let d = Self.stamp.date(from: "\(parts[0])-\(parts[1])") {
            date = d
            kind = parts[2] == "cover" ? .cover : .song
            seed = Int(parts[3])
        } else {
            // Hand-made folders (benchmarks, smoke tests) don't follow the naming scheme.
            date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            kind = id.contains("cover") ? .cover : .song
            seed = nil
        }

        func text(_ name: String) -> String {
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        style = text("style.txt")
        lyrics = text("lyrics.txt")
        abc = text("score.abc")

        var timing: [String: Any] = [:]
        if let data = try? Data(contentsOf: folder.appendingPathComponent("timing.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            timing = obj
        }
        renderSeconds = timing["seconds"] as? Double
        steps = timing["steps"] as? Int
        planning = timing["cot"] as? String
        truncated = timing["truncated"] as? Bool ?? false
        instrumental = timing["instrumental"] as? Bool ?? (lyrics.lowercased() == "[instrumental]")
        if let seconds = timing["audio_seconds"] as? Double {
            duration = seconds
        } else if let url = flac ?? mp3, let file = try? AVAudioFile(forReading: url) {
            duration = Double(file.length) / file.processingFormat.sampleRate
        } else {
            duration = nil
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var songs: [Song] = []

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/YuE2/outputs")

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        songs = dirs.compactMap(Song.init(folder:)).sorted { $0.date > $1.date }
    }

    func song(id: Song.ID?) -> Song? {
        guard let id else { return nil }
        return songs.first { $0.id == id }
    }

    func trash(_ song: Song) {
        try? FileManager.default.trashItem(at: song.folder, resultingItemURL: nil)
        reload()
    }
}
