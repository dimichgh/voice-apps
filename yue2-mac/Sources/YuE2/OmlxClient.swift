import Foundation

/// Lyrics writing and lyric transcription go through the local omlx server
/// (same models as voicedub-mac), not the YuE2 server.
final class OmlxClient {
    static let shared = OmlxClient()

    var baseURL = URL(string: "http://127.0.0.1:8000")!
    // `--` form: omlx resolves ids against HF cache directory names.
    var chatModel = "mlx-community--Qwen3-Omni-30B-A3B-Instruct-8bit"
    var sttModel = "mlx-community--whisper-large-v3-turbo-asr-fp16"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 1200
        return URLSession(configuration: c)
    }()

    // MARK: Lyrics

    func writeLyrics(concept: String, style: String, language: String, structure: String, seed: Int) async throws -> String {
        let prompt = """
        Write original song lyrics for a music-generation model.

        Concept or story: \(concept)
        Musical style: \(style.isEmpty ? "unspecified" : style)
        Language: \(language)
        Requested structure: \(structure)

        Return only the finished lyrics. Use explicit section labels such as [Verse], [Pre-Chorus],
        [Chorus], [Bridge], [Instrumental], and [Outro]. Keep lines singable, use a memorable chorus,
        and avoid commentary, markdown fences, titles, or production instructions.
        """
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": chatModel,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 768,
            "temperature": 0.8,
            "top_p": 0.95,
            "seed": seed,
        ] as [String: Any])

        let (data, resp) = try await send(req)
        try Self.check(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        let lyrics = Self.cleanLyrics(content ?? "")
        if lyrics.isEmpty {
            throw ServerError(message: "The lyric model returned an empty result. Try a more specific concept.")
        }
        return lyrics
    }

    static func cleanLyrics(_ text: String) -> String {
        var s = text
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }
        s = s.replacingOccurrences(of: "```", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Transcription

    /// `language`: Whisper code, nil = auto-detect.
    func transcribe(wav: Data, language: String?) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        req.httpMethod = "POST"
        let boundary = "YuE2Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", sttModel)
        if let language { field("language", language) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, resp) = try await send(req, upload: body)
        try Self.check(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private func send(_ req: URLRequest, upload: Data? = nil) async throws -> (Data, URLResponse) {
        do {
            if let upload { return try await session.upload(for: req, from: upload) }
            return try await session.data(for: req)
        } catch {
            throw ServerError(message: "omlx server is not reachable at \(baseURL.absoluteString) — start it to use this feature.")
        }
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let text = String(data: data, encoding: .utf8) ?? ""
        throw ServerError(message: "omlx error \(http.statusCode): \(text.prefix(300))")
    }
}

enum FFmpeg {
    static var path: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Decode any audio file to 16 kHz mono WAV for ASR.
    static func asrWav(from source: URL) async throws -> Data {
        guard let ffmpeg = path else { throw ServerError(message: "ffmpeg not found (brew install ffmpeg).") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("yue2-asr-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-vn", "-ac", "1", "-ar", "16000", out.path]
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        guard status == 0 else { throw ServerError(message: "ffmpeg could not decode \(source.lastPathComponent).") }
        return try Data(contentsOf: out)
    }
}
