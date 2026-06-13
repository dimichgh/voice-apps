import Foundation
import SwiftUI

@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [Message]
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var status: String = "Ready. Hold Space (outside the text field) or click the mic to talk."
    @Published var voiceReply: Bool = true
    @Published var continuousListening = false

    // Updated from each chat response's `usage` block. promptTokens is the
    // total tokens omlx saw in the *request* (history + tools + last message),
    // i.e. how much of the context window we're already using.
    @Published var promptTokens: Int = 0
    @Published var completionTokens: Int = 0
    @Published var lastUsageStale: Bool = true  // true until first usage arrives

    // 0..1 mic level updated ~10Hz while AudioIO is listening. Lets
    // the UI render a level meter so the user can verify capture is alive.
    @Published var micLevel: Float = 0

    let client = OmlxClient()
    let capture = AudioCapture()
    let playback = AudioPlayer()
    // Full-duplex audio: ONE voice-processing engine for both mic capture and
    // native Talker playback, so AEC removes the assistant's own voice from the
    // mic (no self-barge-in) while keeping the mic live for real interruptions.
    let audioIO = AudioIO()
    let tools = ToolRegistry()
    let voiceCatalog = VoiceCatalog()

    // Tracks the in-flight turn so barge-in can cancel it cleanly.
    private var currentTurn: Task<Void, Never>?

    private var nativeVoiceSelected: Bool { voiceCatalog.current.isQwenNative }

    static let systemPrompt = """
    You are a helpful local voice assistant running on the user's MacBook via Qwen3-Omni-30B-A3B (8-bit MLX).
    ALWAYS respond in English, regardless of the language of the input audio or text, unless the user explicitly asks you to use another language. Never reply in Chinese.
    Keep replies short (1-3 sentences) unless the user asks for detail — your reply will be spoken aloud.
    When a tool can answer faster or more reliably than guessing, call it.
    """

    init() {
        messages = [Message(role: .system, content: Self.systemPrompt)]
        tools.register(GetCurrentTimeTool())
        tools.register(ListDirectoryTool())
        tools.register(RunShellTool())
        tools.register(ReadFileTool())
        tools.register(WriteFileTool())
        tools.register(WebSearchTool())
    }

    // MARK: - Session reset

    func newChat() {
        interrupt()
        if isRecording {
            _ = capture.stop()
            isRecording = false
        }
        messages = [Message(role: .system, content: Self.systemPrompt)]
        promptTokens = 0
        completionTokens = 0
        lastUsageStale = true
        status = continuousListening
            ? "Hands-free listening on. Talk anytime."
            : "Ready."
    }

    // MARK: - Hands-free mode

    func toggleContinuous() {
        if continuousListening { stopContinuous() } else { startContinuous() }
    }

    private func startContinuous() {
        // Push-to-talk would conflict — drain any active capture first.
        interrupt()
        if isRecording {
            _ = capture.stop()
            isRecording = false
        }

        audioIO.onSpeechStart = { [weak self] in
            guard let self else { return }
            // Barge-in: user started talking while assistant was busy/talking.
            // stopPlayback() halts the Talker node but KEEPS the shared engine
            // running so the mic stays live.
            self.playback.stop()
            self.audioIO.stopPlayback()
            self.currentTurn?.cancel()
            self.currentTurn = nil
            self.isBusy = false
            self.status = "Listening…"
        }
        audioIO.onUtterance = { [weak self] wav in
            guard let self else { return }
            // Drop overlapping triggers — finish current turn before next.
            if self.isBusy { return }
            self.currentTurn = Task { [weak self] in
                await self?.handleVoiceTurn(wav: wav)
            }
        }
        audioIO.onLevel = { [weak self] lvl in
            self?.micLevel = lvl
        }
        do {
            try audioIO.startListening()
            continuousListening = true
            status = "Hands-free listening on. Just talk."
        } catch {
            status = "Hands-free start failed: \(error.localizedDescription)"
        }
    }

    private func stopContinuous() {
        audioIO.stopListening()
        continuousListening = false
        micLevel = 0
        status = "Ready."
    }

    /// Pause / resume VAD evaluation. Called around the non-native TTS path so
    /// the assistant doesn't trigger its own listener through the speakers.
    /// (The native Talker path relies on AEC instead, so it stays un-muted.)
    func setListenerMuted(_ muted: Bool) {
        audioIO.muted = muted
    }

    private func waitForPlaybackThenUnmute() async {
        // Poll AVAudioPlayer.isPlaying — cheap and avoids delegate plumbing.
        while playback.isPlaying {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
        }
        // Brief tail so trailing speech tail doesn't re-trigger.
        try? await Task.sleep(nanoseconds: 250_000_000)
        setListenerMuted(false)
    }

    // MARK: - Barge-in / interrupt

    /// Stops any TTS playback and cancels the in-flight turn — used when the
    /// user starts a new recording or sends new text while the assistant is
    /// still working.
    private func interrupt() {
        playback.stop()
        audioIO.stopPlayback()
        currentTurn?.cancel()
        currentTurn = nil
        isBusy = false
    }

    // MARK: - Voice path

    func startRecording() {
        // Press-to-interrupt: kill anything already running before we open the mic.
        if isBusy || playback.isPlaying { interrupt() }
        guard !isRecording else { return }
        do {
            try capture.start()
            isRecording = true
            status = "Listening…"
        } catch {
            status = "Mic error: \(error.localizedDescription)"
        }
    }

    func stopRecordingAndSend() {
        guard isRecording else { return }
        let wav = capture.stop()
        isRecording = false
        currentTurn = Task { [weak self] in
            await self?.handleVoiceTurn(wav: wav)
        }
    }

    private func handleVoiceTurn(wav: Data) async {
        isBusy = true
        defer { isBusy = false; currentTurn = nil }
        do {
            if nativeVoiceSelected && voiceReply {
                // Audio-in: the model hears the raw voice directly (no STT on
                // the critical path).
                try await runNativeAudioInTurn(wav: wav)
            } else {
                // Tool-capable path needs text: transcribe, then chat+TTS.
                try Task.checkCancellation()
                status = "Transcribing…"
                let text = try await client.transcribe(wav: wav)
                try Task.checkCancellation()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    status = "Empty transcription. Try again."
                    return
                }
                messages.append(Message(role: .user, content: trimmed))
                try await runChatLoop(speakReply: voiceReply)
            }
            status = continuousListening ? "Listening…" : "Ready."
        } catch is CancellationError {
            status = "Interrupted."
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                status = "Interrupted."
            } else {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }

    /// Native audio-in turn: send the user's raw WAV straight to the model.
    /// A parallel STT fills in the user's transcript bubble for the UI only —
    /// it never blocks the model response.
    private func runNativeAudioInTurn(wav: Data) async throws {
        guard case .qwenNative(let speaker) = voiceCatalog.current.kind else {
            return
        }
        // Placeholder user bubble; parallel STT fills it in.
        let userMsg = Message(role: .user, content: "🎤 …")
        messages.append(userMsg)
        let userIdx = messages.count - 1
        let displayTask = Task { [weak self] in
            guard let self else { return }
            if let t = try? await self.client.transcribe(wav: wav) {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, userIdx < self.messages.count {
                    self.messages[userIdx].content = trimmed
                }
            }
        }
        defer { displayTask.cancel() }

        status = "Thinking…"
        // Reset the player node for a fresh turn. The shared engine keeps
        // running (it also drives the mic); enqueue() re-arms playback.
        audioIO.stopPlayback()
        // With AEC active the mic stays live (full-duplex barge-in). Without it,
        // mute during playback so the assistant doesn't trigger its own listener.
        let muteForPlayback = continuousListening && !audioIO.aecActive
        if muteForPlayback { audioIO.muted = true }
        defer { if muteForPlayback { audioIO.muted = false } }

        var assistantIndex: Int? = nil
        var gotAudio = false
        for try await event in client.streamVoiceAudio(
            wav: wav, speaker: speaker, systemPrompt: Self.systemPrompt
        ) {
            try Task.checkCancellation()
            switch event {
            case .text(let t):
                DebugLog.log("audioIn: TEXT \(t.prefix(60))")
                messages.append(Message(role: .assistant, content: t))
                assistantIndex = messages.count - 1
                status = "Speaking…"
            case .audioChunk(let pcm):
                if !gotAudio { DebugLog.log("audioIn: first audio \(pcm.count)B") }
                gotAudio = true
                audioIO.enqueue(pcm16: pcm)
            case .error(let e):
                if let i = assistantIndex {
                    messages[i].content = (messages[i].content ?? "") + "\n[audio error: \(e)]"
                } else {
                    messages.append(Message(role: .assistant, content: "[error: \(e)]"))
                }
            case .done:
                break
            }
        }
        if gotAudio && !Task.isCancelled {
            await audioIO.waitUntilDrained()
        }
    }

    // MARK: - Native Qwen3-Omni streaming turn

    /// Streams thinker text + Talker audio from /v1/qwen3_omni/chat/stream.
    /// Audio plays chunk-by-chunk the moment it arrives (low latency); text is
    /// shown when it lands. Cancelling `currentTurn` (barge-in / new utterance)
    /// drops the SSE connection and the server stops the Talker.
    private func runNativeVoiceTurn() async throws {
        guard case .qwenNative(let speaker) = voiceCatalog.current.kind else {
            try await runChatLoop(speakReply: true)
            return
        }
        status = "Thinking…"
        DebugLog.log("runNativeVoiceTurn: start, speaker=\(speaker), msgs=\(messages.count)")
        audioIO.stopPlayback()
        let muteForPlayback = continuousListening && !audioIO.aecActive
        if muteForPlayback { audioIO.muted = true }
        defer { if muteForPlayback { audioIO.muted = false } }

        // Placeholder assistant message we fill in when text arrives.
        var assistantIndex: Int? = nil
        var gotAudio = false

        for try await event in client.streamVoice(messages: messages, speaker: speaker) {
            try Task.checkCancellation()
            switch event {
            case .text(let t):
                DebugLog.log("runNativeVoiceTurn: TEXT \(t.prefix(60))")
                let msg = Message(role: .assistant, content: t)
                messages.append(msg)
                assistantIndex = messages.count - 1
                status = "Speaking…"
            case .audioChunk(let pcm):
                if !gotAudio { DebugLog.log("runNativeVoiceTurn: first audio chunk \(pcm.count)B") }
                gotAudio = true
                audioIO.enqueue(pcm16: pcm)
            case .error(let e):
                if let i = assistantIndex {
                    messages[i].content = (messages[i].content ?? "") + "\n[audio error: \(e)]"
                } else {
                    messages.append(Message(role: .assistant, content: "[error: \(e)]"))
                }
            case .done:
                break
            }
        }

        // Let queued audio finish unless we were interrupted.
        if gotAudio && !Task.isCancelled {
            await audioIO.waitUntilDrained()
        }
    }

    // MARK: - Text path

    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if isBusy || playback.isPlaying { interrupt() }
        messages.append(Message(role: .user, content: t))
        currentTurn = Task { [weak self] in
            await self?.runTextTurn()
        }
    }

    private func runTextTurn() async {
        isBusy = true
        defer { isBusy = false; currentTurn = nil }
        do {
            if nativeVoiceSelected && voiceReply {
                try await runNativeVoiceTurn()
            } else {
                try await runChatLoop(speakReply: voiceReply)
            }
            status = continuousListening ? "Listening…" : "Ready."
        } catch is CancellationError {
            status = "Interrupted."
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                status = "Interrupted."
            } else {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Chat + tool loop

    var maxContext: Int { client.config.maxContext }

    func newChatResetUsage() {
        // Estimate roughly from char count; the next real turn replaces with truth.
        let chars = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        promptTokens = chars / 4
        completionTokens = 0
        lastUsageStale = true
    }

    // MARK: - Compaction

    /// Summarizes the conversation so far into a dense block and replaces the
    /// message history with `[system + summary]`. The conversation can
    /// continue with the model still aware of prior context, but tokens drop
    /// from O(history) to O(summary).
    func compact() {
        guard !isBusy else { return }
        currentTurn = Task { [weak self] in
            await self?.runCompact()
        }
    }

    private func runCompact() async {
        isBusy = true
        defer { isBusy = false; currentTurn = nil }
        status = "Compacting…"

        let summaryPrompt = """
        Summarize this conversation so far in detail. Capture:
          1. The user's goals and what they're working on
          2. Key facts established, decisions made, and constraints
          3. Tool results that matter for ongoing context (cite paths / URLs)
          4. Open questions and tasks still pending

        Output a single dense block. Be specific — this summary will REPLACE \
        the conversation history, so the next assistant turn must be able to \
        continue the work from this summary alone.
        """

        let summarizeMessages = messages + [
            Message(role: .user, content: summaryPrompt)
        ]

        do {
            try Task.checkCancellation()
            let (reply, _) = try await client.chat(
                messages: summarizeMessages,
                tools: []   // disable tools during summarization
            )
            let summary = (reply.content ?? "(empty summary)")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let newSystem = Self.systemPrompt + """


            --- Prior conversation summary ---
            \(summary)
            """
            messages = [Message(role: .system, content: newSystem)]
            newChatResetUsage()
            status = "Compacted. \(promptTokens) tokens in summary."
        } catch is CancellationError {
            status = "Compact interrupted."
        } catch {
            status = "Compact failed: \(error.localizedDescription)"
        }
    }

    private func runChatLoop(speakReply: Bool) async throws {
        for _ in 0..<6 {
            try Task.checkCancellation()
            status = "Thinking…"
            let activeTools = client.config.supportsTools ? tools.openAITools : []
            let (reply, usage) = try await client.chat(messages: messages, tools: activeTools)
            if let u = usage {
                promptTokens = u.prompt_tokens
                completionTokens = u.completion_tokens
                lastUsageStale = false
            }
            try Task.checkCancellation()
            messages.append(reply)
            if let calls = reply.toolCalls, !calls.isEmpty {
                for call in calls {
                    try Task.checkCancellation()
                    status = "Tool: \(call.function.name)"
                    let result = await tools.run(call: call)
                    messages.append(Message(
                        role: .tool,
                        content: result,
                        toolCalls: nil,
                        toolCallID: call.id,
                        name: call.function.name))
                }
                continue
            }
            if speakReply, let content = reply.content, !content.isEmpty {
                try Task.checkCancellation()
                status = "Speaking…"
                let wav = try await client.tts(text: content, voice: voiceCatalog.current)
                try Task.checkCancellation()
                // Mute the continuous listener while TTS plays so the laptop
                // speakers don't trigger it. Re-arm a moment after playback
                // ends. (With headphones there's no echo loop; this is just
                // a safety belt for built-in speakers.)
                setListenerMuted(true)
                try playback.play(wav: wav)
                Task { [weak self] in
                    await self?.waitForPlaybackThenUnmute()
                }
            }
            return
        }
        status = "Tool loop limit reached."
    }
}
