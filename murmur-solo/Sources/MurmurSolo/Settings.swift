import Foundation
import Combine

/// User-tunable settings for Murmur Solo, persisted in UserDefaults.
///
/// Solo is the self-contained sibling of Murmur: transcription runs entirely
/// on-device via a bundled whisper.cpp model — there's no server URL and no
/// cleanup LLM. The default trigger is Right ⌘ (Murmur uses Right ⌥), so both
/// apps can run at once for a side-by-side comparison without fighting over the
/// same key.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// Which side modifier triggers hold-to-talk.
    @Published var trigger: Trigger {
        didSet { defaults.set(trigger.rawValue, forKey: "trigger") }
    }

    /// Spoken language. "auto" lets Whisper detect it (English or otherwise);
    /// pinning a language is slightly faster and avoids mis-detection.
    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }

    /// Play a subtle system sound on start/stop of dictation.
    @Published var soundFeedback: Bool {
        didSet { defaults.set(soundFeedback, forKey: "soundFeedback") }
    }

    enum Trigger: String, CaseIterable, Identifiable {
        case rightCommand
        case rightOption
        case fn

        var id: String { rawValue }
        var label: String {
            switch self {
            case .rightCommand: return "Hold Right ⌘ Command"
            case .rightOption:  return "Hold Right ⌥ Option"
            case .fn:           return "Hold fn (Globe)"
            }
        }
    }

    /// Languages offered in the picker. "auto" first.
    static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ru", "Russian"), ("zh", "Chinese"),
        ("ja", "Japanese"), ("ko", "Korean"), ("uk", "Ukrainian"),
    ]

    private init() {
        trigger = Trigger(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .rightCommand
        language = defaults.string(forKey: "language") ?? "auto"
        soundFeedback = defaults.object(forKey: "soundFeedback") as? Bool ?? true
    }
}
