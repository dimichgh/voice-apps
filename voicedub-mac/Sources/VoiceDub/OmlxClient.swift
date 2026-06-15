import Foundation

struct OmlxConfig {
    var baseURL: URL = URL(string: "http://127.0.0.1:8000")!
    // IDs use the `--` form because omlx's resolve_model_id matches against HF
    // cache directory names (e.g. `models--mlx-community--…`). Sending
    // `mlx-community/…` 404s.
    var chatModel: String = "mlx-community--Qwen3-Omni-30B-A3B-Instruct-8bit"
    var sttModel: String = "mlx-community--whisper-large-v3-turbo-asr-fp16"
    var temperature: Double = 0.3   // low — translation should be faithful, not creative
}

final class OmlxClient {
    var config: OmlxConfig

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 1200
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(config: OmlxConfig = OmlxConfig()) { self.config = config }

    // MARK: - Transcription (with timed segments)

    /// Transcribe a WAV. `language` is the BCP-47-ish hint Whisper uses (nil =
    /// auto-detect). Returns flat text plus timed segments when the model
    /// exposes them.
    func transcribe(wav: Data, language: String? = nil) async throws -> OmlxTranscription {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/audio/transcriptions"))
        req.httpMethod = "POST"
        let boundary = "VoiceDubBoundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendField(boundary: boundary, name: "model", value: config.sttModel)
        // verbose_json asks omlx/mlx-audio for the segment array.
        body.appendField(boundary: boundary, name: "response_format", value: "verbose_json")
        if let language, !language.isEmpty {
            body.appendField(boundary: boundary, name: "language", value: language)
        }
        body.appendFile(boundary: boundary, name: "file", filename: "audio.wav",
                        contentType: "audio/wav", data: wav)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, resp) = try await session.upload(for: req, from: body)
        try Self.check(resp, data)
        return try JSONDecoder().decode(OmlxTranscription.self, from: data)
    }

    // MARK: - Translation (via Qwen3-Omni chat)

    /// Translate `text` into `targetLanguage` (a human-readable name, e.g.
    /// "Spanish"). Returns only the translation. Empty input → empty output.
    func translate(text: String, targetLanguage: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let system = """
        You are a professional dubbing translator. Translate the user's line into \(targetLanguage). \
        Preserve tone and meaning, and keep it roughly the same spoken length so it fits the same \
        screen time. Output ONLY the translation — no quotes, no notes, no preamble.
        """
        let payload = ChatCompletionRequest(
            model: config.chatModel,
            messages: [
                Message(role: .system, content: system),
                Message(role: .user, content: trimmed),
            ],
            stream: false,
            temperature: config.temperature
        )
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Text-to-speech

    func tts(text: String, voice: VoicePreset) async throws -> Data {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/audio/speech"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": voice.model,
            "input": text,
            "response_format": "wav",
            "stream": false,
        ]
        switch voice.kind {
        case .kokoro(let voiceID):
            body["voice"] = voiceID
        case .plainTTS:
            break   // model + input only; zero-shot default voice
        case .omniCloned(let refAudioURL, let refText, _):
            let refData = try Data(contentsOf: refAudioURL)
            body["ref_audio"] = refData.base64EncodedString()
            body["ref_text"] = refText
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        return data
    }

    /// Design a brand-new voice from a natural-language description. omlx routes
    /// the `voice` field to OmniVoice's `instruct` channel, so the description
    /// shapes the timbre. `sampleText` is what the designed voice reads aloud;
    /// we keep the returned WAV as the frozen reference for cloning.
    func designVoice(description: String, model: String, sampleText: String) async throws -> Data {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/audio/speech"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "input": sampleText,
            "voice": description,
            "response_format": "wav",
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        return data
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>"
            throw NSError(domain: "OmlxClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }
    }
}

private extension Data {
    mutating func appendField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
    mutating func appendFile(boundary: String, name: String, filename: String,
                             contentType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
