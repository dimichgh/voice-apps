import Foundation
import Combine

/// User-tunable settings, persisted in UserDefaults. Observable so the menu-bar
/// settings UI and the live pipeline stay in sync.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// Run an LLM cleanup pass after transcription (fix punctuation, drop
    /// filler words). OFF by default: it adds a round-trip to a large model,
    /// and latency is the whole point of dictation.
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }

    /// omlx server base URL.
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: "serverURL") }
    }

    /// STT model id (omlx `--`-delimited HF cache directory name).
    @Published var sttModel: String {
        didSet { defaults.set(sttModel, forKey: "sttModel") }
    }

    /// Chat model id used for the optional cleanup pass.
    @Published var cleanupModel: String {
        didSet { defaults.set(cleanupModel, forKey: "cleanupModel") }
    }

    /// Which side modifier triggers hold-to-talk.
    @Published var trigger: Trigger {
        didSet { defaults.set(trigger.rawValue, forKey: "trigger") }
    }

    /// Play a subtle system sound on start/stop of dictation.
    @Published var soundFeedback: Bool {
        didSet { defaults.set(soundFeedback, forKey: "soundFeedback") }
    }

    enum Trigger: String, CaseIterable, Identifiable {
        case rightOption
        case rightCommand
        case fn

        var id: String { rawValue }
        var label: String {
            switch self {
            case .rightOption:  return "Hold Right ⌥ Option"
            case .rightCommand: return "Hold Right ⌘ Command"
            case .fn:           return "Hold fn (Globe)"
            }
        }
    }

    private init() {
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        serverURL = defaults.string(forKey: "serverURL") ?? "http://127.0.0.1:8000"
        sttModel = defaults.string(forKey: "sttModel")
            ?? "mlx-community--whisper-large-v3-turbo-asr-fp16"
        cleanupModel = defaults.string(forKey: "cleanupModel")
            ?? "mlx-community--Qwen3-Omni-30B-A3B-Instruct-8bit"
        trigger = Trigger(rawValue: defaults.string(forKey: "trigger") ?? "")
            ?? .rightOption
        // Default ON — a tiny audible tick is the clearest "I'm listening" cue.
        soundFeedback = defaults.object(forKey: "soundFeedback") as? Bool ?? true
    }
}
