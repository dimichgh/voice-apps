import Foundation

/// Adds inline **pause** support on top of `OmlxClient.tts`.
///
/// OmniVoice (and the other omlx TTS models) have no native pause/break token —
/// they even strip newlines — so timed silence can't be expressed in the text
/// the model sees. Instead we split the input on `[pause]` tags, synthesize each
/// text run separately, and stitch the WAVs back together with real silence in
/// between.
///
/// Emotion / nonverbal tags (`[laughter]`, `[sigh]`, `[surprise-oh]`, …) are
/// left untouched in the text — only `[pause …]` is intercepted here.
///
/// Supported syntax (case-insensitive):
///   `[pause]`        → default 0.5 s
///   `[pause:1.2s]`   → 1.2 seconds
///   `[pause:1.2]`    → 1.2 seconds (bare number = seconds)
///   `[pause:500ms]`  → 0.5 seconds
extension OmlxClient {
    /// Synthesize `text`, honoring inline `[pause …]` tags. When the text
    /// contains no pause tags this is exactly `tts(text:voice:)` — same single
    /// request, same bytes — so non-pause output is unchanged.
    func speak(text: String, voice: VoicePreset) async throws -> Data {
        let parts = TTSComposer.parse(text)
        let pauseCount = parts.reduce(0) { $0 + ($1.isPause ? 1 : 0) }
        if pauseCount == 0 {
            return try await tts(text: text, voice: voice)
        }

        // Synthesize each spoken run; remember pause gaps in order.
        var clips: [Data] = []        // WAV per spoken run
        var script: [TTSComposer.Part] = []
        for part in parts {
            switch part {
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                clips.append(try await tts(text: trimmed, voice: voice))
                script.append(.text(t))
            case .pause:
                script.append(part)
            }
        }
        guard !clips.isEmpty else {
            // Only pause tags, no speech — return a short silent clip.
            return WAV.silentWav(seconds: TTSComposer.totalPause(parts),
                                 sampleRate: 24_000, channels: 1)
        }

        return try TTSComposer.stitch(clips: clips, script: script)
    }
}

enum TTSComposer {
    enum Part {
        case text(String)
        case pause(seconds: Double)
        var isPause: Bool { if case .pause = self { return true }; return false }
    }

    /// `[pause]`, `[pause:1.2s]`, `[pause:1.2]`, `[pause:500ms]` — nothing else.
    private static let pauseRegex = try! NSRegularExpression(
        pattern: #"\[\s*pause\s*(?::\s*([0-9]*\.?[0-9]+)\s*(ms|s)?\s*)?\]"#,
        options: [.caseInsensitive])

    private static let defaultPause = 0.5
    private static let maxPause = 10.0

    static func parse(_ text: String) -> [Part] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var parts: [Part] = []
        var cursor = 0
        for m in pauseRegex.matches(in: text, range: full) {
            if m.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                parts.append(.text(chunk))
            }
            parts.append(.pause(seconds: duration(of: m, in: ns)))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            parts.append(.text(ns.substring(from: cursor)))
        }
        return parts
    }

    private static func duration(of m: NSTextCheckingResult, in ns: NSString) -> Double {
        guard m.range(at: 1).location != NSNotFound else { return defaultPause }
        let num = Double(ns.substring(with: m.range(at: 1))) ?? defaultPause
        var seconds = num
        if m.range(at: 2).location != NSNotFound,
           ns.substring(with: m.range(at: 2)).lowercased() == "ms" {
            seconds = num / 1000.0
        }
        return min(max(seconds, 0), maxPause)
    }

    static func totalPause(_ parts: [Part]) -> Double {
        parts.reduce(0) { if case .pause(let s) = $1 { return $0 + s }; return $0 }
    }

    /// Concatenate per-run WAV clips, inserting silence for each `.pause` in the
    /// script. Trims the models' lead/trail padding off each clip so a stitched
    /// pause is the gap we asked for, not the gap plus two clips' worth of dead
    /// air. The first clip's format (sample rate / channels) is canonical.
    static func stitch(clips: [Data], script: [Part]) throws -> Data {
        let decoded = try clips.map { try WAV.decode($0) }
        let fmt = decoded[0].format
        var pcm = Data()
        var clipIdx = 0
        for part in script {
            switch part {
            case .text:
                pcm.append(WAV.trimEdgeSilence(decoded[clipIdx].pcm, format: fmt))
                clipIdx += 1
            case .pause(let seconds):
                pcm.append(WAV.silence(seconds: seconds, format: fmt))
            }
        }
        return WAV.encode(pcm: pcm, format: fmt)
    }
}

/// Minimal canonical PCM-WAV reader/writer. Assumes 16-bit integer samples,
/// which is what omlx emits for every TTS model (`audio_to_wav_bytes`).
enum WAV {
    struct Format { var sampleRate: Int; var channels: Int; var bitsPerSample: Int }

    struct Decoded { var format: Format; var pcm: Data }

    enum Err: Error, LocalizedError {
        case notWav, noFmt, noData, unsupported(Int)
        var errorDescription: String? {
            switch self {
            case .notWav:           return "Not a RIFF/WAVE file."
            case .noFmt:            return "WAV missing fmt chunk."
            case .noData:           return "WAV missing data chunk."
            case .unsupported(let b): return "Unsupported WAV bit depth: \(b)."
            }
        }
    }

    static func decode(_ data: Data) throws -> Decoded {
        let b = [UInt8](data)
        guard b.count >= 12,
              b[0...3] == [0x52, 0x49, 0x46, 0x46],   // "RIFF"
              b[8...11] == [0x57, 0x41, 0x56, 0x45]    // "WAVE"
        else { throw Err.notWav }

        var fmt: Format?
        var pcm: Data?
        var i = 12
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<i+4], encoding: .ascii) ?? ""
            let size = Int(le32(b, i + 4))
            let body = i + 8
            guard body + size <= b.count else { break }
            if id == "fmt " && size >= 16 {
                let channels = Int(le16(b, body + 2))
                let sampleRate = Int(le32(b, body + 4))
                let bits = Int(le16(b, body + 14))
                fmt = Format(sampleRate: sampleRate, channels: channels, bitsPerSample: bits)
            } else if id == "data" {
                pcm = data.subdata(in: body..<(body + size))
            }
            i = body + size + (size & 1)   // chunks are word-aligned
        }
        guard let f = fmt else { throw Err.noFmt }
        guard f.bitsPerSample == 16 else { throw Err.unsupported(f.bitsPerSample) }
        guard let p = pcm else { throw Err.noData }
        return Decoded(format: f, pcm: p)
    }

    static func silence(seconds: Double, format f: Format) -> Data {
        let frames = Int((Double(f.sampleRate) * seconds).rounded())
        return Data(count: frames * f.channels * (f.bitsPerSample / 8))
    }

    static func silentWav(seconds: Double, sampleRate: Int, channels: Int) -> Data {
        let f = Format(sampleRate: sampleRate, channels: channels, bitsPerSample: 16)
        return encode(pcm: silence(seconds: seconds, format: f), format: f)
    }

    /// Strip near-silent frames from the head and tail of a clip, keeping a small
    /// guard so onsets aren't clipped. This removes the model's per-utterance
    /// padding so inserted pauses are predictable.
    static func trimEdgeSilence(_ pcm: Data, format f: Format) -> Data {
        guard f.bitsPerSample == 16 else { return pcm }
        let ch = max(f.channels, 1)
        let samples: [Int16] = pcm.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        let frameCount = samples.count / ch
        guard frameCount > 0 else { return pcm }

        let threshold: Int32 = 256                       // ~0.8% of full scale
        let guardFrames = max(1, f.sampleRate / 100)     // ~10 ms kept either side

        func loud(_ frame: Int) -> Bool {
            for c in 0..<ch {
                if abs(Int32(samples[frame * ch + c])) > threshold { return true }
            }
            return false
        }
        var first = 0
        while first < frameCount && !loud(first) { first += 1 }
        if first == frameCount { return Data() }          // entirely silent
        var last = frameCount - 1
        while last > first && !loud(last) { last -= 1 }

        let lo = max(0, first - guardFrames)
        let hi = min(frameCount - 1, last + guardFrames)
        let byteLo = lo * ch * 2
        let byteHi = (hi + 1) * ch * 2
        return pcm.subdata(in: byteLo..<byteHi)
    }

    static func encode(pcm: Data, format f: Format) -> Data {
        let bytesPerSample = f.bitsPerSample / 8
        let byteRate = f.sampleRate * f.channels * bytesPerSample
        let blockAlign = f.channels * bytesPerSample
        let dataLen = pcm.count

        var out = Data()
        out.append(ascii: "RIFF")
        out.append(le32: UInt32(36 + dataLen))
        out.append(ascii: "WAVE")
        out.append(ascii: "fmt ")
        out.append(le32: 16)
        out.append(le16: 1)                       // PCM
        out.append(le16: UInt16(f.channels))
        out.append(le32: UInt32(f.sampleRate))
        out.append(le32: UInt32(byteRate))
        out.append(le16: UInt16(blockAlign))
        out.append(le16: UInt16(f.bitsPerSample))
        out.append(ascii: "data")
        out.append(le32: UInt32(dataLen))
        out.append(pcm)
        return out
    }

    // MARK: byte helpers
    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i+1]) << 8)
    }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i+1]) << 8) | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
    }
}

private extension Data {
    mutating func append(ascii s: String) { append(contentsOf: Array(s.utf8)) }
    mutating func append(le16 v: UInt16) { append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
    mutating func append(le32 v: UInt32) {
        append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                            UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
}
