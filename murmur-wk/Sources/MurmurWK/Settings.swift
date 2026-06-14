import Foundation
import Combine

/// User-tunable settings for Murmur WK (WhisperKit / CoreML build).
///
/// The third sibling: Murmur (omlx/MLX, Right ⌥), Murmur Solo (whisper.cpp/Metal,
/// Right ⌘), and this one (WhisperKit/CoreML, fn). Distinct default triggers so
/// all three can run at once for a side-by-side comparison.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var trigger: Trigger {
        didSet { defaults.set(trigger.rawValue, forKey: "trigger") }
    }
    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    @Published var soundFeedback: Bool {
        didSet { defaults.set(soundFeedback, forKey: "soundFeedback") }
    }

    enum Trigger: String, CaseIterable, Identifiable {
        case fn
        case rightCommand
        case rightOption

        var id: String { rawValue }
        var label: String {
            switch self {
            case .fn:           return "Hold fn (Globe)"
            case .rightCommand: return "Hold Right ⌘ Command"
            case .rightOption:  return "Hold Right ⌥ Option"
            }
        }
    }

    static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ru", "Russian"), ("zh", "Chinese"),
        ("ja", "Japanese"), ("ko", "Korean"), ("uk", "Ukrainian"),
    ]

    private init() {
        trigger = Trigger(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .fn
        language = defaults.string(forKey: "language") ?? "auto"
        soundFeedback = defaults.object(forKey: "soundFeedback") as? Bool ?? true
    }
}
