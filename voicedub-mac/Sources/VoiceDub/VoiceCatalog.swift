import Foundation
import SwiftUI

/// Loads/saves the voice manifest and exposes it to the UI. Recorded and
/// designed voices persist under Application Support/VoiceDub/voices. Falls back
/// to the zero-shot plain-TTS defaults if no manifest is present.
@MainActor
final class VoiceCatalog: ObservableObject {
    @Published var voices: [VoicePreset] = []
    @Published var current: VoicePreset

    init() {
        let loaded = Self.loadVoices()
        self.voices = Self.plainDefaults + loaded
        self.current = Self.plainDefaults[0]
    }

    /// Zero-shot TTS via models omlx discovers — no reference audio needed.
    static let plainDefaults: [VoicePreset] = [
        .init(id: "omnivoice", label: "OmniVoice (fast)",         model: "mlx-community--OmniVoice-bf16", kind: .plainTTS),
        .init(id: "voxcpm2",   label: "VoxCPM2 (higher quality)", model: "mlx-community--VoxCPM2-bf16",   kind: .plainTTS),
    ]

    /// OmniVoice model id used for newly recorded/designed clones.
    static let omniModel = "mlx-community--OmniVoice-bf16"

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
        if let bundleRes = Bundle.main.resourceURL {
            urls.append(bundleRes.appendingPathComponent("voices/voices.json"))
        }
        urls.append(Self.userVoicesDir().appendingPathComponent("voices.json"))
        return urls
    }

    static func userVoicesDir() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport.appendingPathComponent("VoiceDub/voices", isDirectory: true)
    }

    /// Persist a recorded or imported WAV as a new OmniVoice-cloning voice.
    @discardableResult
    func addRecordedVoice(label: String, wav: Data, refText: String,
                          description: String = "user-recorded sample") throws -> VoicePreset {
        try saveCloned(label: label, wav: wav, refText: refText,
                       description: description, idPrefix: "rec")
    }

    /// Persist a designed WAV (returned by OmniVoice's instruct channel) as a
    /// reusable cloning voice. `refText` is the sample sentence it read.
    @discardableResult
    func addDesignedVoice(label: String, wav: Data, refText: String,
                          description: String) throws -> VoicePreset {
        try saveCloned(label: label, wav: wav, refText: refText,
                       description: description, idPrefix: "design")
    }

    private func saveCloned(label: String, wav: Data, refText: String,
                            description: String, idPrefix: String) throws -> VoicePreset {
        let dir = Self.userVoicesDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970)
        let id = "\(idPrefix)-\(stamp)"
        let wavURL = dir.appendingPathComponent("\(id).wav")
        try wav.write(to: wavURL, options: [.atomic])

        let preset = VoicePreset(
            id: id,
            label: label.isEmpty ? "Voice \(stamp)" : label,
            model: Self.omniModel,
            kind: .omniCloned(refAudioPath: wavURL, refText: refText, description: description)
        )
        voices.append(preset)
        current = preset
        try writeUserManifest()
        return preset
    }

    func delete(_ preset: VoicePreset) {
        guard case .omniCloned(let refURL, _, _) = preset.kind else { return }
        try? FileManager.default.removeItem(at: refURL)
        voices.removeAll { $0.id == preset.id }
        if current.id == preset.id { current = Self.plainDefaults[0] }
        try? writeUserManifest()
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
                return VoicePreset(id: e.id, label: e.label, model: e.model,
                                   kind: .kokoro(voiceID: v))
            case "omni_cloned":
                guard let rel = e.ref_audio_path,
                      let text = e.ref_text,
                      let desc = e.description else { return nil }
                let audioURL = baseDir.appendingPathComponent(rel)
                return VoicePreset(id: e.id, label: e.label, model: e.model,
                                   kind: .omniCloned(refAudioPath: audioURL,
                                                     refText: text, description: desc))
            default:
                return nil
            }
        }
    }
}
