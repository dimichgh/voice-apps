import Foundation
import AVFoundation

/// Thin wrapper over the `ffmpeg` / `ffprobe` CLIs for the steps AVFoundation
/// doesn't do cleanly: decoding a video's audio to 16 kHz mono PCM for ASR,
/// time-stretching a generated clip to a target duration, and assembling timed
/// segments into one continuous track.
enum FFmpeg {
    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Resolve a CLI tool. App bundles don't inherit the shell PATH, so probe
    /// the common Homebrew/MacPorts locations explicitly.
    static func toolURL(_ name: String) throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw ToolError(message: "\(name) not found. Install it (e.g. `brew install ffmpeg`).")
    }

    /// Run a tool (resolved from PATH) to completion off the main thread.
    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await runProcess(executable: toolURL(tool), label: tool, args)
    }

    /// Run an explicit executable (e.g. a venv's python) to completion off the
    /// main thread. Throws with captured stderr on non-zero exit.
    @discardableResult
    static func runProcess(executable url: URL, label: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = url
                proc.arguments = args
                let out = Pipe(); let err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error); return
                }
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                    cont.resume(throwing: ToolError(message: "\(label) failed: \(msg.suffix(500))"))
                } else {
                    cont.resume(returning: String(data: outData, encoding: .utf8) ?? "")
                }
            }
        }
    }

    /// Run a tool and return its STDERR (filters like `silencedetect` report
    /// there, and exit 0). Throws only if the process can't be launched.
    static func runStderr(_ tool: String, _ args: [String]) async throws -> String {
        let url = try toolURL(tool)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = url
                proc.arguments = args
                let out = Pipe(); let err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                do { try proc.run() } catch { cont.resume(throwing: error); return }
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                _ = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: String(data: errData, encoding: .utf8) ?? "")
            }
        }
    }

    /// Detect silent intervals `[start, end]` (seconds) via `silencedetect`.
    /// Used to recover the true speech onset for a transcript segment, since
    /// Whisper absorbs leading silence into the segment (reporting start ≈ 0).
    /// On audio with background music/noise nothing may register as silent —
    /// the caller treats an empty result as "leave timings as-is".
    static func detectSilences(in wav: URL, totalDuration: Double,
                               noiseDB: Int = -30, minDur: Double = 0.35) async throws
        -> [(start: Double, end: Double)] {
        let log = try await runStderr("ffmpeg", [
            "-hide_banner", "-nostats", "-i", wav.path,
            "-af", "silencedetect=noise=\(noiseDB)dB:d=\(String(format: "%.2f", minDur))",
            "-f", "null", "-",
        ])
        var result: [(start: Double, end: Double)] = []
        var pendingStart: Double? = nil
        for line in log.split(separator: "\n") {
            if let r = line.range(of: "silence_start:") {
                let token = line[r.upperBound...].split(separator: " ")
                    .first.map(String.init) ?? ""
                pendingStart = Double(token)
            } else if let r = line.range(of: "silence_end:") {
                let token = line[r.upperBound...].split(separator: "|")
                    .first?.trimmingCharacters(in: .whitespaces) ?? ""
                if let end = Double(token) {
                    result.append((pendingStart ?? 0, end))
                    pendingStart = nil
                }
            }
        }
        // Silence running to EOF is reported as a start with no end.
        if let s = pendingStart, totalDuration > s {
            result.append((s, totalDuration))
        }
        return result
    }

    /// OmniVoice effectively uses only ~10s of the cloning reference (its
    /// `ref_audio_max_duration_s`). If `ref_text` describes MORE speech than
    /// that, the untranscribed tail gets *spoken* before the target text.
    /// Empirically (on a 20s real clip): caps ≤12s are clean, ≥15s leak. So cap
    /// the reference here and always transcribe the CAPPED clip so audio and
    /// transcript correspond.
    static let maxRefSeconds = 10.0

    /// Normalize an arbitrary imported audio/video file to a 16 kHz mono PCM16
    /// WAV — the same shape recorded clips use as an OmniVoice cloning reference.
    /// `maxSeconds`, when set, caps the duration (see `maxRefSeconds`).
    static func convertToRefAudio(from input: URL, to wav: URL,
                                  maxSeconds: Double? = nil) async throws {
        var args = ["-y", "-i", input.path, "-vn", "-ac", "1", "-ar", "16000"]
        if let maxSeconds { args += ["-t", String(format: "%.2f", maxSeconds)] }
        args += ["-c:a", "pcm_s16le", wav.path]
        try await run("ffmpeg", args)
    }

    /// Extract a `[start, start+duration]` span as a 16 kHz mono PCM16 WAV — the
    /// OmniVoice cloning-reference format. Used to clone the original speaker
    /// from the video's own audio. (Input seek on uncompressed PCM is accurate.)
    static func extractClip(from input: URL, start: Double, duration: Double,
                            to wav: URL) async throws {
        try await run("ffmpeg", [
            "-y", "-ss", String(format: "%.3f", max(0, start)),
            "-i", input.path,
            "-t", String(format: "%.3f", max(0.1, duration)),
            "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path,
        ])
    }

    /// Decode the video's audio to a 16 kHz mono PCM16 WAV for ASR.
    static func extractAudioForASR(from video: URL, to wav: URL) async throws {
        try await run("ffmpeg", [
            "-y", "-i", video.path,
            "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", wav.path,
        ])
    }

    /// Sample rate used for the full-fidelity audio path (separation + remix).
    static let backgroundRate = 44100

    /// Decode the video's audio at full fidelity (44.1 kHz stereo) — the input to
    /// source separation and the base the dub is mixed back over.
    static func extractFullAudio(from video: URL, to wav: URL) async throws {
        try await run("ffmpeg", [
            "-y", "-i", video.path,
            "-vn", "-ac", "2", "-ar", "\(backgroundRate)",
            "-c:a", "pcm_s16le", wav.path,
        ])
    }

    /// Downmix any audio to 16 kHz mono PCM16 — for ASR and the clone reference
    /// (e.g. from the isolated vocals stem).
    static func downmixForASR(from input: URL, to wav: URL) async throws {
        try await run("ffmpeg", [
            "-y", "-i", input.path,
            "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", wav.path,
        ])
    }

    /// Duration in seconds of an audio/video file via ffprobe.
    static func duration(of url: URL) async throws -> Double {
        let out = try await run("ffprobe", [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ])
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Largest speed-up we'll apply. Beyond this, sped-up speech becomes
    /// unintelligible, so we cap the stretch and let the clip overflow into the
    /// following gap rather than garble it (sync anchors at segment starts).
    static let maxTempo = 1.6

    /// Fit `input` to its source span (`target` seconds) for dubbing:
    ///  - shorter than the span → keep natural pace, pad with silence to `target`
    ///    (so the next segment's start offset stays correct);
    ///  - up to `maxTempo` longer → time-stretch to exactly `target`;
    ///  - beyond `maxTempo` → stretch by `maxTempo` only and let it run long.
    static func fitToDuration(input: URL, target: Double, output: URL) async throws {
        let srcDur = try await duration(of: input)
        guard srcDur > 0.05, target > 0.05 else {
            try await run("ffmpeg", ["-y", "-i", input.path,
                                     "-t", String(format: "%.3f", max(target, 0.05)), output.path])
            return
        }
        // output_duration = src / tempo  ⇒  tempo = src / target.
        let tempo = srcDur / target
        let filters: String
        if tempo <= 1.0 {
            // Already fits — natural pace, pad with silence to fill the span.
            filters = "apad,atrim=0:\(String(format: "%.3f", target))"
        } else if tempo <= maxTempo {
            // Stretch to exactly fill the span.
            filters = atempoChain(tempo) + ",apad,atrim=0:\(String(format: "%.3f", target))"
        } else {
            // Too long even at max speed — cap the speed-up, no trim (overflow).
            filters = atempoChain(maxTempo)
        }
        try await run("ffmpeg", [
            "-y", "-i", input.path,
            "-filter:a", filters,
            output.path,
        ])
    }

    /// Decompose a tempo factor into a chain of atempo stages each within
    /// [0.5, 2.0].
    static func atempoChain(_ tempo: Double) -> String {
        var remaining = max(0.25, min(tempo, 100))   // sane clamp
        var stages: [String] = []
        while remaining > 2.0 {
            stages.append("atempo=2.0"); remaining /= 2.0
        }
        while remaining < 0.5 {
            stages.append("atempo=0.5"); remaining /= 0.5
        }
        stages.append("atempo=\(String(format: "%.4f", remaining))")
        return stages.joined(separator: ",")
    }

    /// Place each `(startSeconds, wavURL)` segment at its start time and mix into
    /// one stereo WAV over a base track. The base has three modes:
    ///  - **gated** (`background` + `original` + `speechSpans`): the full original
    ///    audio *outside* speech spans + the vocals-removed background *inside*
    ///    them. This keeps music/SFX (roars, stingers) at full original dynamics
    ///    in the gaps — separation only bleeds them where speech overlaps — while
    ///    still removing the original voice under the dub.
    ///  - **background-only** (`background` alone): the separated stem everywhere.
    ///  - **silence** (neither): a voice-only dub.
    /// `amix`/`normalize=0` preserves per-clip levels; a limiter catches summed
    /// peaks when mixing voice over real audio.
    static func assemble(segments: [(start: Double, url: URL)],
                         totalDuration: Double,
                         background: URL? = nil,
                         original: URL? = nil,
                         speechSpans: [(start: Double, end: Double)] = [],
                         output: URL) async throws {
        let hasBed = background != nil || original != nil
        let rate = hasBed ? backgroundRate : 24000
        let dur = String(format: "%.3f", max(totalDuration, 0.1))
        func f(_ x: Double) -> String { String(format: "%.3f", x) }

        var args: [String] = ["-y"]
        for seg in segments { args += ["-i", seg.url.path] }
        let baseIdx = segments.count

        var graph = ""
        var voiceLabels: [String] = []
        for (i, seg) in segments.enumerated() {
            let ms = Int(max(0, seg.start) * 1000)
            graph += "[\(i)]aresample=\(rate),aformat=channel_layouts=stereo,adelay=\(ms):all=1[d\(i)];"
            voiceLabels.append("[d\(i)]")
        }

        // Build the base track → label [base].
        if let background, let original, !speechSpans.isEmpty {
            args += ["-i", original.path, "-i", background.path]
            // enable=true only while t is inside a speech span (commas are safe
            // inside the single-quoted expression).
            let mask = speechSpans.map { "between(t,\(f($0.start)),\(f($0.end)))" }
                .joined(separator: "+")
            graph += "[\(baseIdx)]aresample=\(rate),aformat=channel_layouts=stereo,"
                + "volume=0:enable='\(mask)'[og];"          // original muted during speech
            graph += "[\(baseIdx + 1)]aresample=\(rate),aformat=channel_layouts=stereo,"
                + "volume=0:enable='lt(\(mask),0.5)'[bgg];" // background muted outside speech
            graph += "[og][bgg]amix=inputs=2:normalize=0:duration=longest[base];"
        } else if let bed = background ?? original {
            args += ["-i", bed.path]
            graph += "[\(baseIdx)]aresample=\(rate),aformat=channel_layouts=stereo[base];"
        } else {
            args += ["-f", "lavfi", "-t", dur,
                     "-i", "anullsrc=channel_layout=stereo:sample_rate=\(rate)"]
            graph += "[\(baseIdx)]aformat=channel_layouts=stereo[base];"
        }

        if voiceLabels.isEmpty {
            graph += "[base]anull[out]"
        } else {
            graph += "\(voiceLabels.joined())[base]amix=inputs=\(voiceLabels.count + 1):normalize=0:duration=longest"
            graph += hasBed ? ",alimiter=limit=0.95[out]" : "[out]"
        }

        args += [
            "-filter_complex", graph,
            "-map", "[out]",
            "-ac", "2", "-ar", "\(rate)", "-c:a", "pcm_s16le",
            output.path,
        ]
        try await run("ffmpeg", args)
    }
}
