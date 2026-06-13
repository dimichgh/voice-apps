import Foundation
import SwiftUI

/// Loads the voice manifest produced by `design_voices.py` and exposes it to
/// the UI. Falls back to a single built-in Kokoro voice if no manifest is
/// present (so the app still works on a fresh checkout).
@MainActor
final class VoiceCatalog: ObservableObject {
    @Published var voices: [VoicePreset] = []
    @Published var current: VoicePreset

    init() {
        // Pipeline: Whisper STT → LLM (tools) → TTS. Zero-shot TTS
        // (OmniVoice/VoxCPM2) lead, followed by any designed/recorded voices.
        let loaded = Self.loadVoices()
        self.voices = Self.plainDefaults + loaded
        self.current = Self.plainDefaults[0]
    }

    /// Zero-shot TTS via models omlx discovers.
    static let plainDefaults: [VoicePreset] = [
        .init(id: "omnivoice", label: "OmniVoice (fast)",           model: "mlx-community--OmniVoice-bf16", kind: .plainTTS),
        .init(id: "voxcpm2",   label: "VoxCPM2 (higher quality)",   model: "mlx-community--VoxCPM2-bf16", kind: .plainTTS),
    ]

    /// Merges voices from every available manifest (bundle, project tree,
    /// user app-support dir). First-seen id wins, so bundled defaults aren't
    /// silently replaced by stale user copies.
    private static func loadVoices() -> [VoicePreset] {
        var merged: [VoicePreset] = []
        var seen = Set<String>()
        for url in manifestCandidates() {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let parsed = parse(data: data,
                                     baseDir: url.deletingLastPathComponent())
            else { continue }
            for v in parsed where !seen.contains(v.id) {
                merged.append(v)
                seen.insert(v.id)
            }
        }
        return merged
    }

    private static func manifestCandidates() -> [URL] {
        var urls: [URL] = []
        // 1. Inside the .app bundle (build.sh copies voices/ into Resources/).
        if let bundleRes = Bundle.main.resourceURL {
            urls.append(bundleRes.appendingPathComponent("voices/voices.json"))
        }
        // 2. The project working tree — handy during `swift run` development.
        urls.append(URL(fileURLWithPath:
            "/Users/dsemenov/Views/llm/voicechat-mac/voices/voices.json"))
        // 3. User-writable directory — where in-app recordings land.
        urls.append(Self.userVoicesDir().appendingPathComponent("voices.json"))
        return urls
    }

    static func userVoicesDir() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport.appendingPathComponent("VoiceChat/voices",
                                                 isDirectory: true)
    }

    /// Persist a user-recorded WAV as a new OmniVoice-cloning voice preset.
    /// Returns the preset on success.
    @discardableResult
    func addRecordedVoice(label: String, wav: Data, refText: String) throws -> VoicePreset {
        let dir = Self.userVoicesDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970)
        let id = "rec-\(stamp)"
        let wavURL = dir.appendingPathComponent("\(id).wav")
        try wav.write(to: wavURL, options: [.atomic])

        let preset = VoicePreset(
            id: id,
            label: label.isEmpty ? "My Voice \(stamp)" : label,
            model: "mlx-community--OmniVoice-bf16",
            kind: .omniCloned(refAudioPath: wavURL,
                              refText: refText,
                              description: "user-recorded sample")
        )
        voices.append(preset)
        current = preset
        try writeUserManifest()
        return preset
    }

    private func writeUserManifest() throws {
        let dir = Self.userVoicesDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("voices.json")

        var entries: [[String: Any]] = []
        for v in voices {
            guard case .omniCloned(let refURL, let refText, let desc) = v.kind,
                  refURL.path.hasPrefix(dir.path)
            else { continue }
            entries.append([
                "id": v.id,
                "label": v.label,
                "kind": "omni_cloned",
                "model": v.model,
                "description": desc,
                "ref_audio_path": refURL.lastPathComponent,
                "ref_text": refText,
            ])
        }
        let payload: [String: Any] = ["voices": entries]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: [.atomic])
    }

    private static func parse(data: Data, baseDir: URL) -> [VoicePreset]? {
        struct Manifest: Decodable { let voices: [Entry] }
        struct Entry: Decodable {
            let id: String
            let label: String
            let kind: String
            let model: String
            let voice: String?
            let description: String?
            let ref_audio_path: String?
            let ref_text: String?
        }
        guard let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        return decoded.voices.compactMap { e in
            switch e.kind {
            case "kokoro":
                guard let v = e.voice else { return nil }
                return VoicePreset(
                    id: e.id, label: e.label, model: e.model,
                    kind: .kokoro(voiceID: v))
            case "omni_cloned":
                guard let rel = e.ref_audio_path,
                      let text = e.ref_text,
                      let desc = e.description else { return nil }
                let audioURL = baseDir.appendingPathComponent(rel)
                return VoicePreset(
                    id: e.id, label: e.label, model: e.model,
                    kind: .omniCloned(
                        refAudioPath: audioURL,
                        refText: text,
                        description: desc))
            default:
                return nil
            }
        }
    }
}
