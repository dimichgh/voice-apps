import Foundation

/// Server `phase` strings mapped onto an ordered pipeline, so views can tell done / active / pending stages apart.
enum JobPhase: Int, Comparable {
    case idle, queued, loading, planning, tokens, synthesizing, decoding, saving, done, failed, cancelled

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(server phase: String) {
        switch phase {
        case "Loading model", "Loading SheetSage2": self = .loading
        case "Planning score", "Using provided score", "Transcribing melody": self = .planning
        case "Generating song": self = .tokens
        case "Synthesizing audio": self = .synthesizing
        case "Decoding audio": self = .decoding
        case "Saving": self = .saving
        default: self = .queued
        }
    }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .queued: "Waiting for the GPU"
        case .loading: "Loading model"
        case .planning: "Composing score"
        case .tokens: "Generating audio tokens"
        case .synthesizing: "Synthesizing audio"
        case .decoding: "Decoding audio"
        case .saving: "Saving"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Runs one server job and polls it to completion, publishing progress.
@MainActor
final class SongJob: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progressText = ""
    @Published private(set) var fraction: Double?     // nil = indeterminate
    @Published private(set) var errorMessage: String?
    @Published private(set) var result: JobResult?
    @Published private(set) var phase: JobPhase = .idle
    @Published private(set) var tokens = 0
    @Published private(set) var planTokens = 0
    @Published private(set) var step = 0
    @Published private(set) var totalSteps = 0
    @Published private(set) var elapsed: Double = 0
    /// cot=off (and covers with a supplied score) never report a planning phase.
    @Published private(set) var skippedPlanning = false

    /// Called on the main actor when a job finishes successfully.
    var onResult: ((JobResult) -> Void)?

    /// YuE2 codec tokens are 25 per second of audio (measured: 2055 tokens → 82.2 s).
    static let tokensPerSecond = 25.0

    private var jobID: String?
    private var cancelRequested = false
    private var sawPlanning = false

    /// Starts a job and waits for its final status. Returns the result on success.
    @discardableResult
    func run(_ start: () async throws -> JobStatus) async -> JobResult? {
        isRunning = true
        cancelRequested = false
        errorMessage = nil
        progressText = "Submitting…"
        fraction = nil
        phase = .queued
        tokens = 0; planTokens = 0; step = 0; totalSteps = 0; elapsed = 0
        sawPlanning = false
        skippedPlanning = false
        defer { isRunning = false; jobID = nil }
        do {
            var status = try await start()
            jobID = status.id
            if cancelRequested { await ServerClient.shared.cancel(status.id) }
            while !status.isTerminal {
                update(status)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                status = try await ServerClient.shared.job(status.id)
            }
            elapsed = status.elapsed
            switch status.state {
            case "done":
                result = status.result
                progressText = Self.summary(status)
                fraction = 1
                phase = .done
                if let r = status.result { onResult?(r) }
                return status.result
            case "cancelled":
                progressText = "Cancelled"
                fraction = nil
                phase = .cancelled
            default:
                errorMessage = status.error ?? "Generation failed."
                progressText = ""
                phase = .failed
            }
        } catch {
            errorMessage = error.localizedDescription
            progressText = ""
            phase = .failed
        }
        return nil
    }

    func cancel() {
        cancelRequested = true
        progressText = "Cancelling…"
        if let jobID { Task { await ServerClient.shared.cancel(jobID) } }
    }

    private func update(_ s: JobStatus) {
        let next = JobPhase(server: s.phase)
        if next == .planning {
            sawPlanning = true
            planTokens = s.tokens
        } else if next > .planning, !sawPlanning {
            skippedPlanning = true
        }
        phase = next
        tokens = s.tokens
        step = s.step
        totalSteps = s.total_steps
        elapsed = s.elapsed

        let clock = Self.clock(s.elapsed)
        switch s.phase {
        case "Generating song" where s.tokens > 0:
            let audio = Double(s.tokens) / Self.tokensPerSecond
            progressText = "Generating song · \(s.tokens) tokens (~\(Self.clock(audio)) of audio) · \(clock)"
            fraction = nil
        case "Planning score" where s.tokens > 0:
            progressText = "Planning score · \(s.tokens) tokens · \(clock)"
            fraction = nil
        case "Synthesizing audio" where s.total_steps > 0:
            progressText = "Synthesizing audio · \(s.step)/\(s.total_steps) · \(clock)"
            fraction = Double(s.step) / Double(s.total_steps)
        default:
            progressText = "\(s.phase) · \(clock)"
            fraction = nil
        }
    }

    private static func summary(_ s: JobStatus) -> String {
        guard let r = s.result, let audio = r.audio_seconds else { return "Done in \(clock(s.elapsed))" }
        var text = "\(clock(audio)) of audio in \(clock(r.seconds ?? s.elapsed))"
        if r.truncated == true { text += " · hit the token limit (truncated)" }
        return text
    }

    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t)s"
    }
}
