import Foundation
import PersonaPlex
import AudioCommon
import MLX
import SpeechVAD

enum ConversationState: String {
    case inactive
    case listening
    case processing
    case speaking
    case fullDuplex
}

/// The two pre-quantized builds. They are structurally identical — same
/// components quantized, same group_size — and differ only in `bits`, which the
/// library reads from each repo's config.json. So switching is just a modelId.
enum ModelPrecision: String, CaseIterable, Identifiable {
    case eightBit = "8-bit"
    case fourBit = "4-bit"

    var id: String { rawValue }

    var modelId: String {
        switch self {
        case .eightBit: return PersonaPlexModel.modelId8bit
        case .fourBit: return PersonaPlexModel.defaultModelId
        }
    }

    var approxSize: String {
        switch self {
        case .eightBit: return "~9.1 GB"
        case .fourBit: return "~5.4 GB"
        }
    }
}

/// Thread-safe bool shared between the main actor and the audio capture thread.
private final class AgentSpeakingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ speaking: Bool) { lock.withLock { value = speaking } }
    var isSpeaking: Bool { lock.withLock { value } }
}

/// Rolling per-step timing, written from the inference thread and read by the UI.
/// One frame is 80ms; staying under that is the whole latency story.
final class StepMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: [Double] = []
    private var last = CFAbsoluteTimeGetCurrent()
    private(set) var steps = 0

    func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            let dt = (now - last) * 1000
            last = now
            steps += 1
            recent.append(dt)
            if recent.count > 25 { recent.removeFirst() }
        }
    }

    func reset() {
        lock.withLock { recent.removeAll(); steps = 0; last = CFAbsoluteTimeGetCurrent() }
    }

    /// (mean ms/step, worst ms/step in window, steps so far)
    var snapshot: (mean: Double, peak: Double, steps: Int) {
        lock.withLock {
            guard !recent.isEmpty else { return (0, 0, steps) }
            return (recent.reduce(0, +) / Double(recent.count), recent.max() ?? 0, steps)
        }
    }
}

@Observable
@MainActor
final class PersonaPlexViewModel {
    // MARK: - State

    var conversationState: ConversationState = .inactive
    var isLoading = false
    var loadingStatus: String?
    var errorMessage: String?
    var modelTranscript = ""
    var latencyInfo: String?
    var debugInfo: String = ""

    var selectedVoice: PersonaPlexVoice = .NATM0
    var precision: ModelPrecision = .eightBit
    var maxSteps: Int = 75
    var isFullDuplexMode: Bool = true
    /// Mute the mic while the agent speaks. Needed on speakers because VPIO/AEC
    /// is unavailable on this machine — but it also kills barge-in, so it is off
    /// by default and you should wear headphones.
    var echoSuppression: Bool = false

    /// Free text. PersonaPlex's whole point is persona control, and the Swift
    /// tokenizer does expose `encodeSystemPrompt`, so there is no reason to ship
    /// the hardcoded token array the demo used.
    var personaPrompt: String =
        "You are a helpful assistant. Answer questions clearly and concisely. "
        + "Listen carefully to what the user says, then respond directly to their "
        + "question or request. Stay on topic. Be concise."

    /// Precision the currently-loaded weights were built at.
    private(set) var loadedPrecision: ModelPrecision?
    /// VAD weights could not be fetched, so turn-based mode has no
    /// end-of-utterance detection and only full-duplex is offered.
    private(set) var vadUnavailable = false
    let stepMeter = StepMeter()

    // MARK: - Private

    private var model: PersonaPlexModel?
    private var recorder: AudioRecorder?
    private let player = StreamingAudioPlayer()
    private var spmDecoder: SentencePieceDecoder?
    private var vadModel: SileroVADModel?
    private var conversationTask: Task<Void, Never>?
    private let agentSpeakingTracker = AgentSpeakingTracker()

    // MARK: - Computed

    var modelLoaded: Bool { model != nil }
    var isActive: Bool { conversationState != .inactive }
    var audioLevel: Float { recorder?.audioLevel ?? 0 }
    var isBusy: Bool { isLoading }

    // MARK: - Model Loading

    func loadModel() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let wanted = precision
        defer { isLoading = false }

        // Weights come from the HF cache that `mlxmgr install` populated. Going
        // through the library's own downloader would re-fetch several GB over a
        // network path that tends to be blocked here, so resolve the snapshot
        // ourselves and load strictly offline.
        let localDir = Self.localSnapshot(for: wanted.modelId)
        if localDir == nil {
            errorMessage = """
                No local weights for \(wanted.modelId).
                Run:  python3 mlxmgr.py install personaplex-mlx-\(wanted == .eightBit ? "8bit" : "4bit")
                """
            return
        }

        // Drop the old model before loading the new one — two 7B models will not
        // both fit comfortably, and MLX wants one owner.
        Self.releaseModel(model)
        model = nil
        loadedPrecision = nil
        loadingStatus = "Loading PersonaPlex \(wanted.rawValue) (\(wanted.approxSize))..."
        Self.boundMLXCache()
        Self.linkLibraryCache(modelId: wanted.modelId, to: localDir!)

        do {
            let loadStart = CFAbsoluteTimeGetCurrent()

            let m = try await PersonaPlexModel.fromPretrained(
                modelId: wanted.modelId,
                cacheDir: localDir,
                offlineMode: true
            ) { [weak self] progress, status in
                DispatchQueue.main.async {
                    self?.loadingStatus = "\(status) (\(Int(progress * 100))%)"
                }
            }

            loadingStatus = "Warming up (compiling Metal kernels)..."
            let warmStart = CFAbsoluteTimeGetCurrent()
            await Task.detached { m.warmUp() }.value
            let warmTime = CFAbsoluteTimeGetCurrent() - warmStart

            let spmPath = localDir!
                .appendingPathComponent("tokenizer_spm_32k_3.model").path
            if FileManager.default.fileExists(atPath: spmPath) {
                spmDecoder = try SentencePieceDecoder(modelPath: spmPath)
            }

            model = m
            loadedPrecision = wanted

            // Create the recorder FIRST, without VAD. Full-duplex never uses
            // VAD (the model does its own turn-taking), and fetching the VAD
            // weights goes through the library's own downloader — a network
            // path that is blocked here. If that throw landed before the
            // recorder existed, the app would look loaded but capture nothing.
            recorder = AudioRecorder(targetSampleRate: 24000)

            // VAD is only needed to detect end-of-utterance in turn-based mode.
            // Treat a failure as "turn-based unavailable", not "load failed".
            do {
                if vadModel == nil {
                    loadingStatus = "Loading VAD (turn-based mode only)..."
                    vadModel = try await SileroVADModel.fromPretrained(offlineMode: false)
                }
                let vadConfig = VADConfig(
                    onset: 0.5, offset: 0.35,
                    minSpeechDuration: 0.25, minSilenceDuration: 1.0,
                    windowDuration: 0.032, stepRatio: 1.0
                )
                let processor = StreamingVADProcessor(model: vadModel!, config: vadConfig)
                recorder = AudioRecorder(targetSampleRate: 24000, vadProcessor: processor)
            } catch {
                vadUnavailable = true
                isFullDuplexMode = true
            }

            let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
            latencyInfo = String(
                format: "%@ loaded in %.1fs (warmup %.1fs)",
                wanted.rawValue, loadTime, warmTime
            )
            loadingStatus = nil
        } catch {
            errorMessage = "Failed to load \(wanted.rawValue): \(error.localizedDescription)"
            loadingStatus = nil
        }
    }

    /// Resolve an HF repo id to its snapshot directory in the local hub cache.
    nonisolated static func localSnapshot(for modelId: String) -> URL? {
        let hubRoot: URL = {
            if let hf = ProcessInfo.processInfo.environment["HF_HOME"] {
                return URL(fileURLWithPath: hf).appendingPathComponent("hub")
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
        }()
        let repoDir = hubRoot.appendingPathComponent(
            "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        )
        let snapshots = repoDir.appendingPathComponent("snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ) else { return nil }
        // A repo can hold several revisions; take whichever actually has weights.
        for dir in entries where FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("temporal.safetensors").path
        ) {
            return dir
        }
        return nil
    }

    /// Bound MLX's buffer cache.
    ///
    /// The weights are 9.1 GB (8-bit) or 5.4 GB (4-bit), but the process can be
    /// seen holding ~100 GB. That is not a leak and it is not the model: MLX
    /// keeps freed GPU buffers in a scratch pool for reuse instead of returning
    /// them, and mlx-swift's default ceiling for that pool is the Metal device's
    /// `recommendedMaxWorkingSetSize` — **107.5 GB on this 128 GB M5 Max**.
    /// Sustained decoding allocates a lot of transients (per frame: 32 temporal
    /// layers plus 16 depformer steps), so the pool climbs toward that ceiling
    /// and pushes everything else into swap long before MLX feels any pressure.
    ///
    /// Every other model in speech-swift caps this (see
    /// `Qwen3ASRMemory.cacheLimitForLarge`, and the `Memory.clearCache()` calls
    /// in Voxtral/Moss/F5TTS/Chatterbox/Nemotron). PersonaPlex is the one that
    /// sets no limit and calls no clearCache — hence this.
    ///
    /// 8 GB is deliberately more generous than the ASR path's `min(4 GB, 25%)`:
    /// this model's per-step working set is larger and a too-small pool trades
    /// residency for allocator churn, which shows up directly in ms/step. If the
    /// HUD regresses, raise this before suspecting the model.
    nonisolated static func boundMLXCache() {
        let eightGB = 8 * 1024 * 1024 * 1024
        let quarterRAM = Int(ProcessInfo.processInfo.physicalMemory) / 4
        let cap = max(0, min(eightGB, quarterRAM))
        // Never raise a limit somebody else already lowered.
        if cap > 0 && cap < MLX.Memory.cacheLimit {
            MLX.Memory.cacheLimit = cap
        }
    }

    /// Release a loaded model's GPU memory.
    ///
    /// `model = nil` drops the Swift reference but leaves the weight buffers in
    /// MLX's pool, so switching precision would otherwise stack 9.1 GB of 8-bit
    /// underneath 5.4 GB of 4-bit. `unload()` zeroes the parameters and
    /// `clearCache()` hands the pool back.
    nonisolated static func releaseModel(_ m: PersonaPlexModel?) {
        m?.unload()
        MLX.Memory.clearCache()
    }

    /// Point the library's own cache path at the HF snapshot.
    ///
    /// `fromPretrained(cacheDir:)` only governs the weight files. Voice prompts
    /// are loaded separately, at four sites in PersonaPlex.swift, through
    /// `modelCacheDirectory()` — which re-derives the path from `modelId` under
    /// `~/Library/Caches/qwen3-speech/models/<org>/<repo>` and ignores the
    /// cacheDir we passed. Worse, all four sites treat a missing voice file as
    /// "no voice prompt" rather than an error, so without this the model loads,
    /// runs, and sounds generic — silently. Symlinking that path to the snapshot
    /// fixes every site at once and needs no library patch.
    nonisolated static func linkLibraryCache(modelId: String, to snapshot: URL) {
        let fm = FileManager.default
        let parts = modelId.split(separator: "/")
        guard parts.count == 2 else { return }
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/qwen3-speech/models")
            .appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))

        // Already linked where we want it — nothing to do.
        if let dest = try? fm.destinationOfSymbolicLink(atPath: dir.path),
           dest == snapshot.path { return }

        try? fm.createDirectory(at: dir.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // getCacheDirectory() creates this as an empty real directory on first
        // call. Only remove it if it is empty or a stale symlink — never clobber
        // a directory someone actually downloaded weights into.
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: dir.path)) != nil
        let isEmpty = (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? false
        if isLink || isEmpty {
            try? fm.removeItem(at: dir)
        } else if fm.fileExists(atPath: dir.path) {
            return
        }
        try? fm.createSymbolicLink(at: dir, withDestinationURL: snapshot)
    }

    private func promptTokens() -> [Int32]? {
        let text = personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let model else { return nil }
        return model.tokenizeSystemPrompt(text)
    }

    // MARK: - Conversation Control

    func toggleConversation() {
        if conversationState == .inactive {
            if isFullDuplexMode {
                conversationState = .fullDuplex
                conversationTask = Task { await startFullDuplex() }
            } else {
                startListening()
            }
        } else {
            stopConversation()
        }
    }

    private func startListening() {
        conversationState = .listening
        errorMessage = nil
        debugInfo = "Listening..."

        recorder?.onSpeechEnded = { [weak self] in
            Task { @MainActor [weak self] in
                self?.onSpeechEnded()
            }
        }
        recorder?.startRecording()
    }

    private func onSpeechEnded() {
        guard conversationState == .listening else { return }
        debugInfo = "Processing..."
        conversationTask = Task { await processAndRespond() }
    }

    private func stopConversation() {
        conversationTask?.cancel()
        conversationTask = nil
        recorder?.onSpeechEnded = nil
        if recorder?.isRecording == true {
            _ = recorder?.stopRecording()
        }
        player.stop()
        conversationState = .inactive
        debugInfo = ""
    }

    // MARK: - Full-Duplex

    private func startFullDuplex() async {
        guard let model else {
            errorMessage = "Model not loaded."
            conversationState = .inactive
            return
        }

        errorMessage = nil
        debugInfo = "Full-duplex active..."
        agentSpeakingTracker.set(false)
        stepMeter.reset()

        // 5-second ring buffer: enough headroom if inference runs long
        let ringBuffer = AudioRingBuffer(capacity: 24000 * 5)
        let tracker = agentSpeakingTracker

        do {
            let suppressEnabled = echoSuppression
            try recorder?.startContinuous(buffer: ringBuffer) {
                suppressEnabled && tracker.isSpeaking
            }
        } catch {
            errorMessage = "Mic error: \(error.localizedDescription)"
            conversationState = .inactive
            return
        }

        do {
            try player.start(sampleRate: 24000)
        } catch {
            _ = recorder?.stopRecording()
            errorMessage = "Audio output error: \(error.localizedDescription)"
            conversationState = .inactive
            return
        }

        let voice = selectedVoice
        let tokens = promptTokens()
        let meter = stepMeter

        // Capture player ref so the detached task can call scheduleChunk directly
        // without bouncing to MainActor each frame (AVAudioPlayerNode.scheduleBuffer is thread-safe).
        let playerRef = player

        // All inference runs on one detached task for MLX thread safety
        conversationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let stream = model.respondRealtime(
                voice: voice,
                systemPromptTokens: tokens,
                userAudioBuffer: ringBuffer,
                verbose: false
            )

            // Pre-buffer a few frames before playback starts to absorb inference jitter.
            let prebufferCount = 3  // ~240ms cushion
            var prebuffer: [[Float]] = []
            prebuffer.reserveCapacity(prebufferCount)

            do {
                for try await agentSamples in stream {
                    meter.tick()

                    // Track whether the agent is audibly speaking, for the
                    // optional mic gate and the UI indicator.
                    let rms = agentSamples.map { $0 * $0 }.reduce(0, +)
                        / Float(max(agentSamples.count, 1))
                    tracker.set(sqrt(rms) > 0.01)

                    if prebuffer.count < prebufferCount {
                        prebuffer.append(agentSamples)
                        if prebuffer.count == prebufferCount {
                            for frame in prebuffer { playerRef.scheduleChunk(frame) }
                            prebuffer = []
                        }
                    } else {
                        playerRef.scheduleChunk(agentSamples)
                    }
                }
                // Flush any remaining pre-buffered frames
                for frame in prebuffer { playerRef.scheduleChunk(frame) }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = "Full-duplex inference error: \(error.localizedDescription)"
                }
            }

            await MainActor.run { [weak self] in
                self?.stopConversation()
            }
        }

        // Drive the latency HUD off the meter while the session runs.
        Task { @MainActor [weak self] in
            while self?.conversationState == .fullDuplex {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                let s = self.stepMeter.snapshot
                if s.steps > 0 {
                    let verdict = s.mean <= 80 ? "real-time" : "OVER BUDGET"
                    self.latencyInfo = String(
                        format: "%.0f ms/step avg · %.0f peak · %d steps · %@ (budget 80 ms)",
                        s.mean, s.peak, s.steps, verdict
                    )
                }
            }
        }
    }

    // MARK: - Turn-Based

    private func processAndRespond() async {
        let rawAudio = recorder?.stopRecording() ?? []

        guard rawAudio.count > 2400 else {
            startListening()
            return
        }

        conversationState = .processing
        modelTranscript = ""
        latencyInfo = nil

        let audio = Self.trimTrailingSilence(rawAudio, sampleRate: 24000, threshold: 0.01)
        let audioDuration = Double(audio.count) / 24000.0

        guard let model else {
            errorMessage = "Model not loaded."
            stopConversation()
            return
        }

        let voice = selectedVoice
        let tokens = promptTokens()
        let steps = maxSteps
        let spmDec = spmDecoder

        debugInfo = "Generating..."

        let result = await Task.detached(priority: .userInitiated) {
            () -> ([Float], String, Double) in
            let inferStart = CFAbsoluteTimeGetCurrent()
            let (response, textTokens) = model.respond(
                userAudio: audio,
                voice: voice,
                systemPromptTokens: tokens,
                maxSteps: steps
            )
            let inferTime = CFAbsoluteTimeGetCurrent() - inferStart

            var transcript = ""
            if let dec = spmDec, !textTokens.isEmpty {
                transcript = dec.decode(textTokens)
            } else if !textTokens.isEmpty {
                transcript = "(\(textTokens.count) text tokens)"
            }
            return (response, transcript, inferTime)
        }.value

        guard conversationState != .inactive else { return }

        let (response, transcript, inferTime) = result
        modelTranscript = transcript

        let responseDuration = Double(response.count) / 24000.0
        let rtf = inferTime / max(responseDuration, 0.01)
        let msPerStep = inferTime * 1000 / Double(max(steps, 1))

        latencyInfo = String(
            format: "Infer %.1fs · %.0f ms/step · %.1fs in / %.1fs out · RTF %.2f",
            inferTime, msPerStep, audioDuration, responseDuration, rtf
        )

        if !response.isEmpty {
            conversationState = .speaking
            debugInfo = "Speaking..."
            do {
                try player.start(sampleRate: 24000)
                player.scheduleChunk(response)
                await player.waitForCompletion()
                player.stop()
            } catch {
                errorMessage = "Playback error: \(error.localizedDescription)"
            }

            if conversationState == .speaking {
                startListening()
            }
        } else {
            errorMessage = "Model returned empty audio."
            startListening()
        }
    }

    // MARK: - Audio Processing

    nonisolated private static func trimTrailingSilence(
        _ samples: [Float], sampleRate: Int, threshold: Float
    ) -> [Float] {
        let chunkSize = sampleRate / 20
        var lastSpeechEnd = samples.count
        var i = samples.count
        while i > chunkSize {
            i -= chunkSize
            let end = min(i + chunkSize, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            let rms = sqrt(sum / Float(end - i))
            if rms > threshold {
                lastSpeechEnd = end + sampleRate / 10
                break
            }
        }
        return Array(samples.prefix(min(lastSpeechEnd, samples.count)))
    }
}
