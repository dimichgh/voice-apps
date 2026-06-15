import Foundation

/// Wrapper over the Demucs CLI (run from a dedicated venv) for splitting audio
/// into a vocals stem and a background (music/SFX) stem — so a dub can replace
/// only the voice while keeping everything else.
///
/// Setup is out-of-band (see README): a venv at
/// `~/Library/Application Support/VoiceDub/demucs-venv` with `demucs` +
/// `torchcodec` installed. Weights download from Meta's CDN on first run.
enum Demucs {
    struct NotInstalled: LocalizedError {
        var errorDescription: String? {
            "Voice separation isn't set up. Install Demucs into the venv (see README) to keep background music & SFX."
        }
    }

    /// The venv interpreter Demucs was installed into.
    static func pythonURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("VoiceDub/demucs-venv/bin/python")
    }

    /// Whether the separation venv is present and runnable.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL().path)
    }

    /// Separate `input` into vocals + background WAVs under `outDir`. Tries the
    /// Metal (MPS) backend first, falling back to CPU if it errors. Returns the
    /// two stem files (44.1 kHz stereo, as Demucs writes them).
    static func separateVocals(from input: URL, outDir: URL) async throws
        -> (vocals: URL, background: URL) {
        guard isAvailable else { throw NotInstalled() }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        do {
            try await run(input: input, outDir: outDir, device: "mps")
        } catch {
            DebugLog.log("demucs mps failed (\(error.localizedDescription)) — retrying on cpu")
            try await run(input: input, outDir: outDir, device: "cpu")
        }
        // Demucs writes outDir/<model>/<track>/{vocals,no_vocals}.wav.
        guard let vocals = firstFile(named: "vocals.wav", under: outDir),
              let background = firstFile(named: "no_vocals.wav", under: outDir) else {
            throw FFmpeg.ToolError(message: "Demucs ran but produced no stems.")
        }
        return (vocals, background)
    }

    private static func run(input: URL, outDir: URL, device: String) async throws {
        try await FFmpeg.runProcess(executable: pythonURL(), label: "demucs", [
            "-m", "demucs",
            "--two-stems", "vocals",
            "-d", device,
            "-o", outDir.path,
            input.path,
        ])
    }

    private static func firstFile(named name: String, under dir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in en where url.lastPathComponent == name { return url }
        return nil
    }
}
