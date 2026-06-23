import Foundation

struct OmlxConfig {
    var baseURL: URL = URL(string: "http://127.0.0.1:8000")!
    // IDs use the `--` form because omlx's resolve_model_id matches against
    // HF cache directory names (e.g. `models--mlx-community--…`). Sending
    // `mlx-community/…` 404s — the resolver only strips a `/` prefix, it
    // does NOT translate slashes to double-dashes.
    // Chat LLM: Gemma 4 12B Instruct (8-bit). Smarter conversational model;
    // omlx parses its tool-calls into OpenAI format, so function calling works
    // (verified). Runs via the mlx-vlm engine (gemma4_unified).
    var chatModel: String = "mlx-community--gemma-4-12B-it-8bit"
    var sttModel: String = "mlx-community--whisper-large-v3-turbo-asr-fp16"
    var temperature: Double = 0.7
    // Whether the chat model understands OpenAI-style `tools`. Qwen3 has native
    // <tool_call> function calling; gemma-4-*-it ships a tool-calling chat
    // template too, so this can stay true when switching to gemma-4-12B-it-8bit.
    var supportsTools: Bool = true
    // Gemma 4 12B supports a very large context, but keep the display/compaction
    // budget conservative.
    var maxContext: Int = 32_768
}

/// A TTS voice the user can pick. Two flavors:
///  - `kokoro` — Kokoro named preset (`voice=af_heart`), small + deterministic.
///  - `omniCloned` — designed via OmniVoice's `instruct` and frozen by sending
///    the captured WAV back as `ref_audio` + `ref_text`. Deterministic because
///    the reference audio is fixed.
struct VoicePreset: Hashable, Identifiable {
    enum Kind: Hashable {
        case kokoro(voiceID: String)
        case omniCloned(refAudioPath: URL, refText: String, description: String)
        // Zero-shot TTS with a discovered model (OmniVoice / VoxCPM2) — no ref
        // audio. Reliable + fast; voice timbre may vary slightly per turn.
        case plainTTS
        // Qwen3-Omni's own Talker — streams thinker text + 24kHz audio in one
        // pass. speaker is one of Ethan / Chelsie / Aiden.
        // EXPERIMENTAL: blocked by an mlx-vlm generate bug (degenerate output).
        case qwenNative(speaker: String)
    }
    let id: String
    let label: String
    let model: String
    let kind: Kind

    var isQwenNative: Bool {
        if case .qwenNative = kind { return true }
        return false
    }
}

/// One decoded SSE event from /v1/qwen3_omni/chat/stream.
enum VoiceStreamEvent {
    case text(String)
    case audioChunk(Data)   // PCM16 LE, 24 kHz mono
    case done
    case error(String)
}

final class OmlxClient {
    var config: OmlxConfig

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(config: OmlxConfig = OmlxConfig()) { self.config = config }

    func transcribe(wav: Data) async throws -> String {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/audio/transcriptions"))
        req.httpMethod = "POST"
        let boundary = "VoiceChatBoundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendField(boundary: boundary, name: "model", value: config.sttModel)
        body.appendFile(boundary: boundary, name: "file", filename: "audio.wav",
                        contentType: "audio/wav", data: wav)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, resp) = try await session.upload(for: req, from: body)
        try Self.check(resp, data)
        return try JSONDecoder().decode(AudioTranscriptionResponse.self, from: data).text
    }

    func chat(messages: [Message], tools: [Tool]) async throws -> (message: Message, usage: UsageInfo?) {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ChatCompletionRequest(
            model: config.chatModel,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            stream: false,
            temperature: config.temperature
        )
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let msg = decoded.choices.first?.message else {
            throw NSError(domain: "OmlxClient", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No choices in chat response"])
        }
        return (msg, decoded.usage)
    }

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
            // omlx accepts base64 in `ref_audio`. ref_text is the transcript of
            // the reference WAV — needed for OmniVoice cloning quality.
            let refData = try Data(contentsOf: refAudioURL)
            body["ref_audio"] = refData.base64EncodedString()
            body["ref_text"] = refText
        case .qwenNative:
            // Native voices stream through streamVoice(), not this TTS path.
            throw NSError(domain: "OmlxClient", code: 99,
                          userInfo: [NSLocalizedDescriptionKey:
                            "qwenNative voice must use streamVoice(), not tts()"])
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        return data
    }

    /// Stream a Qwen3-Omni native voice turn. Yields text once, then audio
    /// chunks as the Talker produces them. Cancelling the consuming Task tears
    /// down the URLSession byte stream, which disconnects from omlx and makes
    /// the server stop the Talker (barge-in).
    /// Audio-in: stream a native voice turn from the user's RAW audio (no STT).
    /// The model hears the audio directly. `systemPrompt` carries the persona /
    /// brevity instruction.
    func streamVoiceAudio(wav: Data, speaker: String, systemPrompt: String)
        -> AsyncThrowingStream<VoiceStreamEvent, Error> {
        streamNative(speaker: speaker) { body in
            body["audio_base64"] = wav.base64EncodedString()
            body["messages"] = [["role": "system", "content": systemPrompt]]
            // Short replies — speech, not essays.
            body["max_tokens"] = 200
        }
    }

    func streamVoice(messages: [Message], speaker: String) -> AsyncThrowingStream<VoiceStreamEvent, Error> {
        streamNative(speaker: speaker) { body in
            // Native endpoint takes role/content pairs only (no tools).
            let wire = messages.compactMap { m -> [String: String]? in
                guard let c = m.content, !c.isEmpty else { return nil }
                return ["role": m.role.rawValue, "content": c]
            }
            body["messages"] = wire
            body["max_tokens"] = 512
        }
    }

    /// Shared SSE driver for the native /v1/qwen3_omni/chat/stream endpoint.
    private func streamNative(speaker: String, fillBody: @escaping (inout [String: Any]) -> Void)
        -> AsyncThrowingStream<VoiceStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/qwen3_omni/chat/stream"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var body: [String: Any] = [
                        "model": config.chatModel,
                        "voice": speaker,
                        "temperature": config.temperature,
                        "stream": true,
                    ]
                    fillBody(&body)
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let wireCount = (body["messages"] as? [[String: String]])?.count ?? 0

                    DebugLog.log("streamNative: POST \(req.url?.absoluteString ?? "") msgs=\(wireCount) audio=\(body["audio_base64"] != nil) speaker=\(speaker)")
                    let (bytes, resp) = try await self.session.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    DebugLog.log("streamVoice: HTTP \(code)")
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: NSError(
                            domain: "OmlxClient", code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "voice stream HTTP \(http.statusCode)"]))
                        return
                    }

                    // SSE parser. NOTE: URLSession.AsyncBytes.lines coalesces the
                    // blank delimiter lines between events, so we cannot rely on
                    // empty lines to terminate an event. Our server emits exactly
                    // one `data:` line per event, immediately after its `event:`
                    // line — so we dispatch as soon as a `data:` line arrives.
                    var event = ""
                    var lineCount = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        lineCount += 1
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            self.emit(event: event, data: String(payload), into: continuation)
                        }
                    }
                    DebugLog.log("streamVoice: stream ended, \(lineCount) lines total")
                    continuation.finish()
                } catch is CancellationError {
                    DebugLog.log("streamVoice: cancelled")
                    continuation.finish()
                } catch {
                    DebugLog.log("streamVoice: ERROR \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func emit(event: String, data: String,
                      into continuation: AsyncThrowingStream<VoiceStreamEvent, Error>.Continuation) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return
        }
        switch event {
        case "text":
            if let t = obj["text"] as? String { continuation.yield(.text(t)) }
        case "audio":
            if let b64 = obj["pcm16_base64"] as? String,
               let pcm = Data(base64Encoded: b64) {
                continuation.yield(.audioChunk(pcm))
            }
        case "error":
            continuation.yield(.error(obj["error"] as? String ?? "unknown"))
        case "done":
            continuation.yield(.done)
        default:
            break
        }
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
