import Foundation

// MARK: - Voices

/// A TTS voice the user can pick. Three flavors:
///  - `kokoro` — Kokoro named preset (`voice=af_heart`), small + deterministic.
///  - `omniCloned` — recorded or designed via OmniVoice, frozen by sending the
///    captured WAV back as `ref_audio` + `ref_text`. Deterministic.
///  - `plainTTS` — zero-shot TTS with a discovered model (OmniVoice / VoxCPM2),
///    no reference audio.
struct VoicePreset: Hashable, Identifiable {
    enum Kind: Hashable {
        case kokoro(voiceID: String)
        case omniCloned(refAudioPath: URL, refText: String, description: String)
        case plainTTS
    }
    let id: String
    let label: String
    let model: String
    let kind: Kind
}

// MARK: - Transcription / segments

/// One timed dialog segment from the omlx transcription endpoint. Times are in
/// seconds relative to the start of the extracted audio.
struct DubSegment: Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    /// Verbatim source-language transcript (editable in the segment editor).
    var sourceText: String
    /// Translation into the target language (nil = no translation requested,
    /// dub uses sourceText). Editable.
    var translatedText: String? = nil
    /// The `speakText` value the currently assembled audio reflects (nil = this
    /// segment has never been voiced). When it differs from the live `speakText`,
    /// the row is *stale*: the text was edited but the audio hasn't caught up.
    var voicedText: String? = nil

    var duration: Double { max(0, end - start) }
    /// Text that should be spoken in the dub: the translation when present and
    /// non-empty, otherwise the source transcript.
    var speakText: String {
        if let t = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty { return t }
        return sourceText
    }
    /// Canonical, trimmed text actually sent to TTS — the single source of truth
    /// for both voicing and staleness (so the comparison stays symmetric).
    var textToVoice: String { speakText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// True when the assembled audio no longer matches the (edited) text. Uses
    /// "" for never-voiced so a segment that gains text after an empty generate
    /// still flags as needing a voice.
    var needsRevoice: Bool { (voicedText ?? "") != textToVoice }
}

// MARK: - Chat (used for translation via Qwen3-Omni)

enum Role: String, Codable {
    case system, user, assistant, tool
}

struct Message: Codable {
    var role: Role
    var content: String?
}

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double?
}

struct ChatResponse: Decodable {
    struct Choice: Decodable {
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Wire decoding for /v1/audio/transcriptions

/// omlx returns OpenAI-style `text` plus an oMLX `segments` array (each with
/// start/end/text) when the STT model supports it. We decode leniently so a
/// model that only returns flat text still works (segments == nil).
struct OmlxTranscription: Decodable {
    struct Segment: Decodable {
        let start: Double?
        let end: Double?
        let text: String?
    }
    let text: String
    let segments: [Segment]?
}
