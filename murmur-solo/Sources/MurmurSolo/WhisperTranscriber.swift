import Foundation
import CWhisper

/// On-device speech-to-text via whisper.cpp (Metal). Loads the bundled GGML
/// model once and reuses the context across dictations.
///
/// whisper.cpp's context is NOT thread-safe — only one transcription may run at
/// a time — so this is an actor. Audio comes in as 16 kHz mono Float32 samples
/// (exactly what AudioRecorder produces), which is whisper's native input.
actor WhisperTranscriber {
    enum TranscriberError: Error, LocalizedError {
        case modelMissing(String)
        case loadFailed(String)
        case inferenceFailed

        var errorDescription: String? {
            switch self {
            case .modelMissing(let p): return "Model not found at \(p)"
            case .loadFailed(let p):   return "Couldn't load model at \(p)"
            case .inferenceFailed:     return "Transcription failed"
            }
        }
    }

    private var ctx: OpaquePointer?
    private let modelPath: String

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    /// Load the model into memory. Expensive (~1s for large-v3-turbo) — call
    /// once at launch so the first dictation isn't slow.
    func preload() throws {
        try loadIfNeeded()
    }

    private func loadIfNeeded() throws {
        if ctx != nil { return }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriberError.modelMissing(modelPath)
        }
        var cparams = whisper_context_default_params()
        cparams.flash_attn = true   // enabled by default for Metal
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw TranscriberError.loadFailed(modelPath)
        }
        ctx = c
        DebugLog.log("Whisper: model loaded (\(modelPath))")
    }

    /// Transcribe 16 kHz mono Float32 samples. `language` is an ISO code or
    /// "auto" to detect.
    func transcribe(samples: [Float], language: String) throws -> String {
        try loadIfNeeded()
        guard let ctx else { throw TranscriberError.loadFailed(modelPath) }
        guard !samples.isEmpty else { return "" }

        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime   = false
        params.print_progress   = false
        params.print_timestamps = false
        params.print_special    = false
        params.translate        = false
        params.no_timestamps    = true
        params.single_segment   = false
        params.suppress_blank   = true
        params.suppress_nst     = true   // suppress non-speech tokens (anti-hallucination)
        params.n_threads        = Int32(maxThreads)

        // The language C string must outlive the whisper_full() call, which runs
        // synchronously inside this closure — so withCString is safe here.
        let lang = language.isEmpty ? "auto" : language
        let text: String = lang.withCString { cLang in
            // language="auto" makes whisper auto-detect AND transcribe.
            // detect_language MUST stay false: when true, whisper detects the
            // language and exits WITHOUT transcribing (zero segments).
            params.language = cLang
            params.detect_language = false
            let rc = samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
            guard rc == 0 else { return "\u{0}FAIL" }
            var out = ""
            let n = whisper_full_n_segments(ctx)
            for i in 0..<n {
                // Drop segments whisper itself flags as non-speech — this is what
                // kills the "you" / random-word hallucinations on silence.
                if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.6 { continue }
                if let seg = whisper_full_get_segment_text(ctx, i) {
                    out += String(cString: seg)
                }
            }
            return out
        }
        if text == "\u{0}FAIL" { throw TranscriberError.inferenceFailed }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
