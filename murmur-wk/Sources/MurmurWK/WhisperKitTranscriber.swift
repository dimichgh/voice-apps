import Foundation
import WhisperKit

/// On-device speech-to-text via WhisperKit (CoreML / Apple Neural Engine).
/// Loads the bundled large-v3-turbo CoreML model and a bundled tokenizer
/// entirely offline (`download: false`), so it never touches the network.
actor WhisperKitTranscriber {
    enum TranscriberError: Error, LocalizedError {
        case modelMissing(String)
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .modelMissing(let p): return "Model folder not found at \(p)"
            case .notLoaded:           return "WhisperKit not loaded"
            }
        }
    }

    private var pipe: WhisperKit?
    private let modelFolder: String
    private let tokenizerFolder: String?

    init(modelFolder: String, tokenizerFolder: String?) {
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
    }

    /// Load + specialize the CoreML models. Expensive on the very first run
    /// (CoreML specializes the model to this chip and caches it), fast after.
    func preload() async throws {
        if pipe != nil { return }
        guard FileManager.default.fileExists(atPath: modelFolder) else {
            throw TranscriberError.modelMissing(modelFolder)
        }
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            tokenizerFolder: tokenizerFolder.map { URL(fileURLWithPath: $0) },
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false          // fully offline: no Hugging Face fetch
        )
        pipe = try await WhisperKit(config)
        DebugLog.log("WhisperKit: model loaded (\(modelFolder))")
    }

    /// Transcribe 16 kHz mono Float32 samples (AudioRecorder's output).
    func transcribe(samples: [Float], language: String) async throws -> String {
        try await preload()
        guard let pipe else { throw TranscriberError.notLoaded }
        guard !samples.isEmpty else { return "" }

        var opts = DecodingOptions()
        opts.task = .transcribe
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = true
        if language != "auto" { opts.language = language }

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
        return results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
