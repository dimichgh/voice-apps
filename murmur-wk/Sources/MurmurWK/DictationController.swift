import Foundation
import AppKit
import Combine

/// The brain. Identical UX to Murmur Solo, but transcription goes through
/// WhisperKit (CoreML/ANE) instead of whisper.cpp (Metal) — that's the whole
/// point of this build: an A/B against the other two engines.
@MainActor
final class DictationController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case inserting
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var locked = false
    @Published private(set) var modelReady = false

    private let recorder = AudioRecorder()
    private let transcriber: WhisperKitTranscriber
    private var hotkey: HotkeyMonitor

    private var pressTime: TimeInterval = 0
    private var lastTapUp: TimeInterval = 0
    private let holdFloor: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.4
    private let maxRecordingSeconds: UInt64 = 60
    private var maxDurationTask: Task<Void, Never>?

    var onPermissionDenied: (() -> Void)?

    init(modelFolder: String, tokenizerFolder: String?) {
        transcriber = WhisperKitTranscriber(modelFolder: modelFolder, tokenizerFolder: tokenizerFolder)
        hotkey = HotkeyMonitor(trigger: Settings.shared.trigger)
        recorder.onLevel = { [weak self] lvl in self?.level = lvl }
        hotkey.onEvent = { [weak self] edge in self?.handle(edge) }
        hotkey.onPermissionDenied = { [weak self] in
            self?.phase = .error("Grant Input Monitoring / Accessibility")
            self?.onPermissionDenied?()
        }
    }

    func start() {
        hotkey.start()
        Task.detached(priority: .utility) { [transcriber] in
            do {
                try await transcriber.preload()
                await MainActor.run { self.modelReady = true }
                DebugLog.log("Controller: model ready")
            } catch {
                DebugLog.log("Controller: model preload failed — \(error.localizedDescription)")
                await MainActor.run { self.phase = .error("Model failed to load") }
            }
        }
    }

    func updateTrigger(_ t: Settings.Trigger) {
        hotkey.updateTrigger(t)
    }

    // MARK: - Gesture interpretation

    private func handle(_ edge: HotkeyMonitor.Edge) {
        let now = ProcessInfo.processInfo.systemUptime
        switch edge {
        case .down:
            pressTime = now
            if !recorder.isRecording { beginRecording() }

        case .up:
            let held = now - pressTime
            if locked {
                locked = false
                finishRecording()
                return
            }
            if held >= holdFloor {
                finishRecording()
                lastTapUp = 0
                return
            }
            if now - lastTapUp < doubleTapWindow {
                locked = true
                lastTapUp = 0
                DebugLog.log("Controller: locked (hands-free)")
            } else {
                cancelRecording()
                lastTapUp = now
            }
        }
    }

    // MARK: - Pipeline

    private func beginRecording() {
        do {
            try recorder.start()
            phase = .listening
            level = 0
            HUDController.shared.show()
            if Settings.shared.soundFeedback { NSSound(named: "Tink")?.play() }
            DebugLog.log("Controller: listening")
            maxDurationTask?.cancel()
            maxDurationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: (self?.maxRecordingSeconds ?? 60) * 1_000_000_000)
                guard let self, self.recorder.isRecording else { return }
                DebugLog.log("Controller: max duration reached — auto-stopping")
                self.locked = false
                self.finishRecording()
            }
        } catch {
            DebugLog.log("Controller: recorder.start failed — \(error.localizedDescription)")
            phase = .error("Microphone unavailable")
            flashErrorThenHide()
        }
    }

    private func cancelRecording() {
        maxDurationTask?.cancel()
        _ = recorder.stop()
        phase = .idle
        HUDController.shared.hide()
    }

    private func finishRecording() {
        maxDurationTask?.cancel()
        let samples = recorder.stop()
        if Settings.shared.soundFeedback { NSSound(named: "Pop")?.play() }
        let peak = samples.map { abs($0) }.max() ?? 0
        let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        DebugLog.log("Controller: captured \(samples.count) samples, peak=\(String(format: "%.4f", peak)) rms=\(String(format: "%.4f", rms))")
        guard samples.count > Int(Double(recorder.sampleRate) * 0.2) else {
            DebugLog.log("Controller: clip too short, discarding")
            phase = .idle
            HUDController.shared.hide()
            return
        }
        // Energy gate: skip transcription on (near-)silence to avoid hallucinations.
        guard peak > 0.012, rms > 0.0035 else {
            DebugLog.log("Controller: below speech energy — skipping")
            phase = .idle
            HUDController.shared.hide()
            return
        }
        phase = .transcribing
        Task { await runPipeline(samples: samples) }
    }

    private func runPipeline(samples: [Float]) async {
        do {
            let text = try await transcriber.transcribe(samples: samples, language: Settings.shared.language)
            DebugLog.log("Controller: transcript = \"\(text)\"")
            guard !text.isEmpty else {
                phase = .idle
                HUDController.shared.hide()
                return
            }
            guard TextInjector.canInject else {
                phase = .error("Grant Accessibility to type")
                onPermissionDenied?()
                TextInjector.requestAccessibility()
                flashErrorThenHide()
                return
            }
            phase = .inserting
            TextInjector.insert(text)
            try? await Task.sleep(nanoseconds: 250_000_000)
            phase = .idle
            HUDController.shared.hide()
        } catch {
            DebugLog.log("Controller: pipeline error — \(error.localizedDescription)")
            phase = .error("Transcription failed")
            flashErrorThenHide()
        }
    }

    private func flashErrorThenHide() {
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            phase = .idle
            HUDController.shared.hide()
        }
    }
}
