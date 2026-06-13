import Foundation
import AppKit
import Combine

/// The brain. Owns the state machine and the gesture interpretation, drives the
/// HUD via @Published state, and wires hotkey → record → transcribe → paste.
///
/// Gestures (both built on the same single side-modifier key):
///   • Hold-to-talk  — hold the key, speak, release. Transcribes on release.
///   • Double-tap-to-lock — two quick taps start a hands-free session that
///     records until you tap once more. Lets you talk without holding the key.
@MainActor
final class DictationController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening       // mic open, capturing
        case transcribing    // waiting on STT (+ optional cleanup)
        case inserting       // pasting into the focused app
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0      // 0...1 live mic level
    @Published private(set) var locked = false        // hands-free session active

    private let recorder = AudioRecorder()
    private let client = TranscriptionClient()
    private var hotkey: HotkeyMonitor

    // Gesture timing.
    private var pressTime: TimeInterval = 0
    private var lastTapUp: TimeInterval = 0
    private let holdFloor: TimeInterval = 0.35        // ≥ this = a real hold
    private let doubleTapWindow: TimeInterval = 0.4   // two taps within = lock

    var onPermissionDenied: (() -> Void)?

    init() {
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
                // A tap during a hands-free session ends it.
                locked = false
                finishRecording()
                return
            }

            if held >= holdFloor {
                // Genuine push-to-talk hold.
                finishRecording()
                lastTapUp = 0
                return
            }

            // Short tap → part of a double-tap?
            if now - lastTapUp < doubleTapWindow {
                // Second quick tap: lock into a hands-free session. We've been
                // recording since this tap's .down, so just keep going.
                locked = true
                lastTapUp = 0
                DebugLog.log("Controller: locked (hands-free)")
            } else {
                // Lone short tap: drop the sliver of audio and arm double-tap.
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
            if Settings.shared.soundFeedback {
                NSSound(named: "Tink")?.play()
            }
            DebugLog.log("Controller: listening")
        } catch {
            DebugLog.log("Controller: recorder.start failed — \(error.localizedDescription)")
            phase = .error("Microphone unavailable")
            flashErrorThenHide()
        }
    }

    private func cancelRecording() {
        recorder.stop()
        phase = .idle
        HUDController.shared.hide()
    }

    private func finishRecording() {
        let wav = recorder.stop()
        if Settings.shared.soundFeedback {
            NSSound(named: "Pop")?.play()
        }
        // ~0.2s floor: anything shorter is a misfire, not speech.
        guard wav.count > 44 + Int(16_000 * 2 * 0.2) else {
            DebugLog.log("Controller: clip too short, discarding")
            phase = .idle
            HUDController.shared.hide()
            return
        }
        phase = .transcribing
        Task { await runPipeline(wav: wav) }
    }

    private func runPipeline(wav: Data) async {
        do {
            var text = try await client.transcribe(wav: wav)
            DebugLog.log("Controller: transcript = \"\(text)\"")
            if Settings.shared.cleanupEnabled, !text.isEmpty {
                let cleaned = try await client.cleanup(text)
                if !cleaned.isEmpty { text = cleaned }
                DebugLog.log("Controller: cleaned = \"\(text)\"")
            }
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
            // Brief beat so the HUD shows "inserting" before vanishing.
            try? await Task.sleep(nanoseconds: 250_000_000)
            phase = .idle
            HUDController.shared.hide()
        } catch {
            DebugLog.log("Controller: pipeline error — \(error.localizedDescription)")
            phase = .error(shortError(error))
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

    private func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "Can't reach omlx server" }
        return "Transcription failed"
    }
}
