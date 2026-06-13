import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var voiceCatalog: VoiceCatalog
    @State private var draft: String = ""
    @State private var keyMonitor: Any?
    @State private var showRecorder = false
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            transcriptView
            Divider()
            composerView
            statusBar
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { uninstallKeyMonitor() }
        .sheet(isPresented: $showRecorder) {
            VoiceRecorderSheet(catalog: voiceCatalog)
        }
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            Button {
                session.toggleContinuous()
            } label: {
                Label(
                    session.continuousListening ? "Listening" : "Hands-free",
                    systemImage: session.continuousListening ? "ear.fill" : "ear"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(session.continuousListening ? .green : .accentColor)
            .help("Toggle continuous listening with energy VAD. Pauses while the assistant speaks. Use headphones for true barge-in.")

            if session.continuousListening {
                MicLevelMeter(level: session.micLevel)
                    .frame(width: 110, height: 10)
            }

            Spacer()

            Button {
                session.compact()
            } label: {
                Label("Compact", systemImage: "rectangle.compress.vertical")
            }
            .buttonStyle(.bordered)
            .help("Summarize the conversation so far and replace history with the summary. Conversation continues; tokens drop.")
            .disabled(session.isBusy || session.promptTokens < 1500)

            Button {
                session.newChat()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
            }
            .buttonStyle(.bordered)
            .help("Start a fresh conversation. System prompt is preserved.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var transcriptView: some View {
        ScrollViewReader { sp in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages.filter { $0.role != .system }) { m in
                        MessageView(message: m).id(m.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: session.messages.count) { _ in
                if let last = session.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        sp.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composerView: some View {
        HStack(spacing: 8) {
            TextField("Type or hold Space outside this field to talk…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .onSubmit { submit() }
                .disabled(session.isBusy)

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(draft.isEmpty || session.isBusy)

            Button(action: micPressed) {
                Image(systemName: session.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .foregroundColor(session.isRecording ? .red : .accentColor)
                    .font(.system(size: 28))
                    .opacity(session.continuousListening ? 0.35 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(session.continuousListening)
            .help(session.continuousListening
                  ? "Push-to-talk disabled in hands-free mode"
                  : (session.isRecording ? "Stop and send" : "Start recording"))

            Toggle("Voice reply", isOn: $session.voiceReply)
                .toggleStyle(.switch)
                .controlSize(.small)

            Picker("", selection: $voiceCatalog.current) {
                ForEach(voiceCatalog.voices) { v in
                    Text(v.label).tag(v)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .help("TTS voice. Designed via design_voices.py or recorded in-app.")
            .disabled(!session.voiceReply)

            Button {
                showRecorder = true
            } label: {
                Image(systemName: "mic.badge.plus")
            }
            .buttonStyle(.bordered)
            .help("Record your own voice sample to use as a custom voice.")
            .disabled(session.continuousListening || session.isRecording)
        }
        .padding(10)
        .background(.thinMaterial)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(session.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if session.isBusy {
                ProgressView().controlSize(.small)
            }
            ContextIndicator(
                used: session.promptTokens,
                max: session.maxContext,
                stale: session.lastUsageStale
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func submit() {
        let text = draft
        draft = ""
        session.sendText(text)
    }

    private func micPressed() {
        if session.isRecording {
            session.stopRecordingAndSend()
        } else {
            // startRecording() handles barge-in: it stops any active TTS playback
            // and cancels the current turn if the assistant was still working.
            session.startRecording()
        }
    }

    // Spacebar push-to-talk — disabled while the text field is focused or
    // while hands-free mode owns the mic.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let inText = NSApp.keyWindow?.firstResponder is NSText
            if event.keyCode == 49, !inText, !session.continuousListening {  // 49 = Space
                if event.type == .keyDown && !event.isARepeat {
                    session.startRecording()
                    return nil
                }
                if event.type == .keyUp {
                    session.stopRecordingAndSend()
                    return nil
                }
            }
            return event
        }
    }

    private func uninstallKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

struct MicLevelMeter: View {
    /// Linear RMS in [0, 1] (typical speech ~0.02-0.15). We map to a bar
    /// width with a knee at the VAD threshold so the user can see when
    /// they're loud enough to trigger.
    let level: Float

    private let threshold: Float = 0.012

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > threshold ? Color.green : Color.gray)
                    .frame(width: CGFloat(min(1.0, level / 0.2)) * geo.size.width)
                // VAD threshold tick.
                Rectangle()
                    .fill(Color.orange.opacity(0.9))
                    .frame(width: 1.5)
                    .offset(x: CGFloat(threshold / 0.2) * geo.size.width)
            }
        }
        .help("Mic level. Bar turns green when you're above the VAD threshold (orange tick).")
    }
}

struct ContextIndicator: View {
    let used: Int
    let max: Int
    let stale: Bool

    private var ratio: Double {
        guard max > 0 else { return 0 }
        return min(1.0, Double(used) / Double(max))
    }
    private var color: Color {
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(fmt(used))\(stale ? "~" : "") / \(fmt(max))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(width: 90, height: 6)
        }
        .help(stale
              ? "Estimated context use; refreshes after the next request."
              : "Context tokens used by the last request: \(used) / \(max).")
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}

struct MessageView: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(header)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let calls = message.toolCalls {
                    ForEach(calls) { call in
                        toolCallBubble(call)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func toolCallBubble(_ call: ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("→ \(call.function.name)")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.orange)
            Text(call.function.arguments)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(6)
    }

    private var iconName: String {
        switch message.role {
        case .system: return "gearshape"
        case .user: return "person.crop.circle.fill"
        case .assistant: return "sparkles"
        case .tool: return "wrench.and.screwdriver.fill"
        }
    }
    private var iconColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .purple
        case .tool: return .orange
        case .system: return .gray
        }
    }
    private var header: String {
        switch message.role {
        case .system: return "system"
        case .user: return "you"
        case .assistant: return "assistant"
        case .tool: return "tool · \(message.name ?? "")"
        }
    }
}
